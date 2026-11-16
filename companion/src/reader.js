const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline/promises');
const { stdin, stdout } = require('node:process');
const { DatabaseSync } = require('node:sqlite');
const { Client, LocalAuth } = require('whatsapp-web.js');
const qrcode = require('qrcode-terminal');
const appMode = process.env.RKAVIC_APP_MODE === '1';

function emitAppEvent(event) {
  if (appMode) process.stdout.write(`RKAVIC_EVENT:${JSON.stringify(event)}\n`);
}

const retentionDays = 30;
const root = process.env.LOCALAPPDATA || path.join(process.env.USERPROFILE, 'AppData', 'Local');
const dataDirectory = path.join(root, 'RKAVICTeamManager', 'whatsapp-reader');
const retentionMs = retentionDays * 24 * 60 * 60 * 1000;
fs.mkdirSync(dataDirectory, { recursive: true });

const database = new DatabaseSync(path.join(dataDirectory, 'messages.sqlite'));
database.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS captured_messages (
    message_id TEXT PRIMARY KEY,
    group_id TEXT NOT NULL,
    sender_id TEXT,
    sender_name TEXT,
    sent_at TEXT NOT NULL,
    text TEXT NOT NULL,
    message_type TEXT NOT NULL DEFAULT 'chat',
    poll_json TEXT
  );
  CREATE INDEX IF NOT EXISTS captured_messages_time ON captured_messages(sent_at DESC);
  CREATE TABLE IF NOT EXISTS captured_poll_votes (
    poll_message_id TEXT NOT NULL,
    voter_id TEXT NOT NULL,
    voter_name TEXT,
    selected_options TEXT NOT NULL,
    interacted_at TEXT NOT NULL,
    PRIMARY KEY (poll_message_id, voter_id)
  );
  CREATE TABLE IF NOT EXISTS captured_reactions (
    message_id TEXT NOT NULL,
    group_id TEXT NOT NULL,
    sender_id TEXT NOT NULL,
    sender_name TEXT,
    emoji TEXT NOT NULL,
    reacted_at TEXT NOT NULL,
    PRIMARY KEY (message_id, sender_id)
  );
`);
const messageColumns = new Set(database.prepare('PRAGMA table_info(captured_messages)').all().map((column) => column.name));
if (!messageColumns.has('message_type')) database.exec("ALTER TABLE captured_messages ADD COLUMN message_type TEXT NOT NULL DEFAULT 'chat'");
if (!messageColumns.has('poll_json')) database.exec('ALTER TABLE captured_messages ADD COLUMN poll_json TEXT');
if (!messageColumns.has('sender_name')) database.exec('ALTER TABLE captured_messages ADD COLUMN sender_name TEXT');
const voteColumns = new Set(database.prepare('PRAGMA table_info(captured_poll_votes)').all().map((column) => column.name));
if (!voteColumns.has('voter_name')) database.exec('ALTER TABLE captured_poll_votes ADD COLUMN voter_name TEXT');
const reactionColumns = new Set(database.prepare('PRAGMA table_info(captured_reactions)').all().map((column) => column.name));
if (!reactionColumns.has('sender_name')) database.exec('ALTER TABLE captured_reactions ADD COLUMN sender_name TEXT');
const deleteOld = database.prepare('DELETE FROM captured_messages WHERE sent_at < ?');
deleteOld.run(new Date(Date.now() - retentionMs).toISOString());
database.exec('DELETE FROM captured_poll_votes WHERE poll_message_id NOT IN (SELECT message_id FROM captured_messages)');
const insertMessage = database.prepare(`
  INSERT OR IGNORE INTO captured_messages
    (message_id, group_id, sender_id, sender_name, sent_at, text, message_type, poll_json)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
`);
const updateMessageSender = database.prepare('UPDATE captured_messages SET sender_name = ? WHERE message_id = ?');
const hasCapturedMessage = database.prepare('SELECT 1 FROM captured_messages WHERE message_id = ?');
const upsertVote = database.prepare(`
  INSERT INTO captured_poll_votes (poll_message_id, voter_id, voter_name, selected_options, interacted_at)
  VALUES (?, ?, ?, ?, ?)
  ON CONFLICT(poll_message_id, voter_id) DO UPDATE SET
    voter_name = COALESCE(excluded.voter_name, captured_poll_votes.voter_name),
    selected_options = excluded.selected_options, interacted_at = excluded.interacted_at
`);
const hasCapturedPoll = database.prepare("SELECT 1 FROM captured_messages WHERE message_id = ? AND message_type = 'poll'");
const upsertReaction = database.prepare(`
  INSERT INTO captured_reactions (message_id, group_id, sender_id, sender_name, emoji, reacted_at)
  VALUES (?, ?, ?, ?, ?, ?)
  ON CONFLICT(message_id, sender_id) DO UPDATE SET
    sender_name = COALESCE(excluded.sender_name, captured_reactions.sender_name),
    emoji = excluded.emoji, reacted_at = excluded.reacted_at
`);
const updateReactionSender = database.prepare('UPDATE captured_reactions SET sender_name = ? WHERE message_id = ? AND sender_id = ?');
const deleteReaction = database.prepare('DELETE FROM captured_reactions WHERE message_id = ? AND sender_id = ?');
function pruneExpired() {
  deleteOld.run(new Date(Date.now() - retentionMs).toISOString());
  database.exec('DELETE FROM captured_poll_votes WHERE poll_message_id NOT IN (SELECT message_id FROM captured_messages)');
  database.exec('DELETE FROM captured_reactions WHERE message_id NOT IN (SELECT message_id FROM captured_messages)');
}

const rl = readline.createInterface({ input: stdin, output: stdout });
const selectionPath = path.join(dataDirectory, 'selected-group.json');
const selectionRequestPath = path.join(dataDirectory, 'selection-request.json');
const groupsPath = path.join(dataDirectory, 'groups.json');
let client;
let stopped = false;

function savedSelection() {
  try {
    const value = JSON.parse(fs.readFileSync(selectionPath, 'utf8'));
    return typeof value.id === 'string' && typeof value.name === 'string' ? value : null;
  } catch (_) {
    return null;
  }
}

function writeJsonAtomic(filePath, value) {
  const temporaryPath = `${filePath}.tmp`;
  fs.writeFileSync(temporaryPath, JSON.stringify(value, null, 2));
  fs.renameSync(temporaryPath, filePath);
}

async function chooseGroup(groups) {
  const saved = savedSelection();
  if (saved && groups.some((group) => group.id._serialized === saved.id)) {
    const answer = (await rl.question(`Capture only “${saved.name}”? [Y/n/select] `))
      .trim().toLowerCase();
    if (!answer || answer === 'y' || answer === 'yes') return saved;
    if (answer !== 'select') return null;
  }

  console.log('\nGroups visible to the linked account:');
  groups.forEach((group, index) => console.log(`${index + 1}. ${group.name}`));
  const answer = (await rl.question('Enter one group number, or q to stop: ')).trim();
  if (answer.toLowerCase() === 'q') return null;
  const index = Number(answer) - 1;
  if (!Number.isInteger(index) || index < 0 || index >= groups.length) {
    console.log('Invalid selection.');
    return chooseGroup(groups);
  }
  const group = groups[index];
  const selection = { id: group.id._serialized, name: group.name };
  fs.writeFileSync(selectionPath, JSON.stringify(selection, null, 2));
  return selection;
}

function isToday(timestamp) {
  const messageDate = new Date(timestamp * 1000);
  const today = new Date();
  return messageDate.getFullYear() === today.getFullYear() &&
    messageDate.getMonth() === today.getMonth() &&
    messageDate.getDate() === today.getDate();
}

function isTodayMilliseconds(timestamp) {
  return Number.isFinite(timestamp) && isToday(timestamp / 1000);
}

function isPollMessage(message) {
  return message.type === 'poll_creation' ||
    (typeof message.pollName === 'string' && Array.isArray(message.pollOptions));
}

function captureMessage(message, groupId, senderName = null) {
  const isPoll = isPollMessage(message);
  if (!isPoll && (message.type !== 'chat' || !message.body || !message.body.trim())) return false;
  const poll = isPoll ? {
    question: message.pollName || message.body || 'Poll',
    options: (message.pollOptions || []).map((option) => option.name),
    allowMultipleAnswers: Boolean(message.allowMultipleAnswers),
  } : null;
  const text = isPoll ? `${poll.question}\n${poll.options.map((option) => `• ${option}`).join('\n')}` : message.body;
  const sentAt = new Date(message.timestamp * 1000).toISOString();
  const senderId = message.fromMe ? 'me' : (message.author || message.from);
  const displayName = senderName && !senderName.endsWith('@lid') ? senderName : null;
  const result = insertMessage.run(
    message.id._serialized,
    groupId,
    senderId,
    displayName,
    sentAt,
    text,
    isPoll ? 'poll' : 'chat',
    poll ? JSON.stringify(poll) : null,
  );
  if (displayName && senderId !== 'me') updateMessageSender.run(displayName, message.id._serialized);
  if (result.changes) pruneExpired();
  return result.changes === 1;
}

function isReadableTextMessage(message) {
  return (message.type === 'chat' && typeof message.body === 'string' && message.body.trim().length > 0) ||
    isPollMessage(message);
}

function displayMessage(message) {
  if (isPollMessage(message)) {
    const options = (message.pollOptions || []).map((option) => `  - ${option.name}`).join('\n');
    return `POLL: ${message.pollName || message.body || '(question unavailable)'}${options ? `\n${options}` : '\n  (options unavailable)'}`;
  }
  return message.body;
}

function captureVote(vote, groupId, voterName = null) {
  const pollMessage = vote.parentMessage;
  const chatId = pollMessage && (pollMessage.fromMe ? pollMessage.to : pollMessage.from);
  const pollMessageId = pollMessage?.id?._serialized || pollMessage?.id?.$1 ||
    vote.parentMsgKey?._serialized || vote.parentMsgKey?.$1;
  if (chatId !== groupId || !pollMessageId || !vote.voter ||
      !hasCapturedPoll.get(pollMessageId)) return false;
  const displayName = voterName && !voterName.endsWith('@lid') ? voterName : null;
  upsertVote.run(pollMessageId, vote.voter, displayName, JSON.stringify(vote.selectedOptions || []),
    new Date(vote.interractedAtTs || Date.now()).toISOString());
  return true;
}

const voterLabels = new Map();

async function voterLabel(voterId) {
  if (voterLabels.has(voterId)) return voterLabels.get(voterId);
  let resolvedLabel = voterId;
  try {
    const contact = await client.getContactById(voterId);
    resolvedLabel = contact?.name || contact?.pushname || contact?.shortName || resolvedLabel;
  } catch (_) { /* A LID may not resolve as a contact directly. */ }

  if (resolvedLabel === voterId && voterId.endsWith('@lid') &&
      typeof client.getContactLidAndPhone === 'function') {
    try {
      const [mapping] = await client.getContactLidAndPhone([voterId]);
      if (mapping?.pn) {
        try {
          const contact = await client.getContactById(mapping.pn);
          resolvedLabel = contact?.name || contact?.pushname || contact?.shortName || mapping.pn.replace(/@[^@]+$/, '');
        } catch (_) {
          resolvedLabel = mapping.pn.replace(/@[^@]+$/, '');
        }
      }
    } catch (_) { /* WhatsApp may not expose a LID-to-phone mapping. */ }
  }
  if (resolvedLabel !== voterId || !voterId.endsWith('@lid')) voterLabels.set(voterId, resolvedLabel);
  return resolvedLabel;
}

async function senderLabel(message) {
  if (message.fromMe) return 'you';
  const senderId = message.author || message.from;
  return senderId ? voterLabel(senderId) : 'member';
}

function normalizedId(value) {
  if (typeof value === 'string') return value;
  return value?._serialized || value?.$1 || null;
}

function captureReaction(messageId, groupId, senderId, emoji, timestamp, senderName = null) {
  if (!messageId || !groupId || !senderId) return false;
  if (!emoji) {
    deleteReaction.run(messageId, senderId);
    return true;
  }
  const timeValue = timestamp || Math.floor(Date.now() / 1000);
  const displayName = senderName && !senderName.endsWith('@lid') ? senderName : null;
  upsertReaction.run(messageId, groupId, senderId, displayName, emoji,
    new Date(timeValue > 1e12 ? timeValue : timeValue * 1000).toISOString());
  if (displayName) updateReactionSender.run(displayName, messageId, senderId);
  return true;
}

async function readMessageReactions(message, groupId) {
  try {
    const groups = await message.getReactions();
    const reactions = [];
    for (const reactionGroup of groups || []) {
      for (const sender of reactionGroup.senders || []) {
        const senderId = sender.senderId || sender.id?.participant || sender.id?.remote || 'unknown';
        const senderName = await voterLabel(senderId);
        captureReaction(message.id._serialized, groupId, senderId, sender.reaction || reactionGroup.aggregateEmoji || reactionGroup.id, sender.timestamp, senderName);
        reactions.push({ senderId, senderName, emoji: sender.reaction || reactionGroup.aggregateEmoji || reactionGroup.id });
      }
    }
    return reactions;
  } catch (error) {
    console.log(`  Reactions unavailable: ${error.message || error}`);
    return [];
  }
}

async function printMessageReactions(reactions) {
  if (!reactions.length) return;
  const items = [];
  for (const reaction of reactions) {
    const me = client.info?.wid?._serialized === reaction.senderId || client.info?.wid?.$1 === reaction.senderId;
    const who = me ? 'you' : await voterLabel(reaction.senderId);
    items.push(`${reaction.emoji} ${who}`);
  }
  console.log(`  Reactions: ${items.join('; ')}`);
}

async function printPollVotes(votes, groupId) {
  const latestByVoter = new Map();
  const orderedVotes = [...votes].sort((a, b) => (a.interractedAtTs || 0) - (b.interractedAtTs || 0));
  for (const vote of orderedVotes) {
    captureVote(vote, groupId, vote.voter ? await voterLabel(vote.voter) : null);
    if (vote.voter) latestByVoter.set(vote.voter, vote);
  }
  if (!latestByVoter.size) {
    console.log('  No voter records are currently available.');
    return;
  }
  console.log('  Votes:');
  for (const [voterId, vote] of latestByVoter) {
    const name = await voterLabel(voterId);
    const choices = (vote.selectedOptions || []).map((option) => option.name).filter(Boolean).join(', ');
    console.log(`    ${name}: ${choices || '(no options selected)'}`);
  }
}

async function cacheGroupHistory(selection) {
  try {
    const chat = await client.getChatById(selection.id);
    if (!chat || !chat.isGroup) throw new Error('Selected group is unavailable.');
    const history = await chat.fetchMessages({ limit: 1000 });
    for (const message of history) {
      const chatId = message.fromMe ? message.to : message.from;
      if (chatId !== selection.id || !isReadableTextMessage(message)) continue;
      captureMessage(message, selection.id, await senderLabel(message));
      if (isPollMessage(message)) {
        try {
          const votes = await client.getPollVotes(message.id._serialized);
          for (const vote of votes || []) {
            captureVote(vote, selection.id, vote.voter ? await voterLabel(vote.voter) : null);
          }
        } catch (_) { /* Vote history is best-effort when WhatsApp omits it. */ }
      }
      await readMessageReactions(message, selection.id);
    }
    console.log(`Loaded ${history.length} recent message(s) for ${selection.name}.`);
  } catch (error) {
    console.error(`Could not load recent messages for ${selection.name}: ${error.message || error}`);
  }
}

async function sendLoop(getSelection) {
  console.log('Text sending is available only to the selected group. Each message requires typing SEND to confirm.');
  while (!stopped) {
    const text = (await rl.question('Message to send (or /exit to stop the reader): ')).trim();
    if (text.toLowerCase() === '/exit') {
      await shutdown();
      return;
    }
    if (!text) continue;
    const selection = getSelection();
    console.log(`\nTo: ${selection.name}\nMessage:\n${text}\n`);
    const confirm = (await rl.question(`Send this message to "${selection.name}"? Type SEND to confirm: `)).trim();
    if (confirm !== 'SEND') {
      console.log('Not sent.');
      continue;
    }
    try {
      await client.sendMessage(selection.id, text);
      console.log('Message sent.');
    } catch (error) {
      console.error(`Could not send message: ${error.message || error}`);
    }
  }
}

async function shutdown() {
  if (stopped) return;
  stopped = true;
  try { if (client) await client.destroy(); } catch (_) { /* Closing anyway. */ }
  try { database.close(); } catch (_) { /* Already closed. */ }
  rl.close();
}

async function main() {
  console.log('RKAVIC WhatsApp group reader — reader and sender prototype');
  console.log(`Stores selected-group text, polls, and reactions locally for ${retentionDays} days. No media is saved.`);
  console.log('This unofficial client can break or lead to WhatsApp account restrictions.');
  const consent = appMode
    ? process.env.RKAVIC_CAPTURE_CONSENT
    : (await rl.question(
      'Confirm group members have been informed about capture. Type YES to continue: ',
    )).trim();
  if (consent !== 'YES') return shutdown();

  const chromePaths = [
    path.join(process.env.PROGRAMFILES || 'C:\\Program Files', 'Google', 'Chrome', 'Application', 'chrome.exe'),
    path.join(process.env['PROGRAMFILES(X86)'] || 'C:\\Program Files (x86)', 'Google', 'Chrome', 'Application', 'chrome.exe'),
    path.join(process.env.LOCALAPPDATA || '', 'Google', 'Chrome', 'Application', 'chrome.exe'),
  ];
  const chromePath = chromePaths.find((candidate) => candidate && fs.existsSync(candidate));
  if (!chromePath) {
    throw new Error('Google Chrome was not found. Install Chrome, then run this reader again.');
  }

  client = new Client({
    puppeteer: { executablePath: chromePath },
    authStrategy: new LocalAuth({
      clientId: 'rkavic-reader',
      dataPath: path.join(dataDirectory, appMode ? 'linked-device-app' : 'linked-device'),
    }),
  });
  client.on('qr', (qr) => {
    if (appMode) {
      emitAppEvent({ type: 'pairing_qr', qr });
      return;
    }
    console.log('\nScan using WhatsApp → Linked devices → Link a device.');
    qrcode.generate(qr, { small: true });
  });
  client.on('authenticated', () => console.log('Linked. Loading groups…'));
  client.on('auth_failure', (error) => {
    console.error(`Authentication failed: ${error}`);
    emitAppEvent({ type: 'auth_failure', message: String(error) });
  });
  client.on('disconnected', (reason) => {
    console.error(`Disconnected: ${reason}`);
    emitAppEvent({ type: 'disconnected', reason: String(reason) });
  });
  client.on('ready', async () => {
    try {
      const chats = await client.getChats();
      const groups = chats.filter((chat) => chat.isGroup);
      writeJsonAtomic(groupsPath, groups.map((group) => ({
        id: group.id._serialized,
        name: group.name,
      })).sort((left, right) => left.name.localeCompare(right.name)));
      emitAppEvent({ type: 'groups_loaded', count: groups.length });
      if (!groups.length) {
        console.log('No groups are available to this linked account.');
        return;
      }
      try {
        const request = JSON.parse(fs.readFileSync(selectionRequestPath, 'utf8'));
        const requestedGroup = groups.find((group) => group.id._serialized === request.id);
        if (requestedGroup) {
          writeJsonAtomic(selectionPath, {
            id: requestedGroup.id._serialized,
            name: requestedGroup.name,
          });
        }
      } catch (_) { /* No pending app selection. */ }
      let selection;
      let readChoice;
      if (appMode) {
        const saved = savedSelection();
        selection = saved && groups.some((group) => group.id._serialized === saved.id)
          ? saved
          : null;
        readChoice = selection ? '1' : '';
      } else {
        selection = await chooseGroup(groups);
        if (!selection) return shutdown();
        readChoice = (await rl.question(
          'What should I read? [1] All messages and polls from today  [2] Latest message (show all votes if poll)  [Enter] Skip: ',
        )).trim().toLowerCase();
      }
      if (!appMode && ['1', '2'].includes(readChoice)) {
        const chat = await client.getChatById(selection.id);
        if (!chat || !chat.isGroup) throw new Error('Selected group is unavailable.');
        // Puppeteer may serialize Infinity as null. whatsapp-web.js then skips
        // its load-earlier loop and returns only the messages already in memory.
        // A very large finite limit keeps the loop active until history is exhausted.
        const historyMessages = await chat.fetchMessages({ limit: Number.MAX_SAFE_INTEGER });
        console.log(`WhatsApp returned ${historyMessages.length} history message(s) for the selected group.`);
        const availableMessages = historyMessages.filter((message) => {
          const chatId = message.fromMe ? message.to : message.from;
          return chatId === selection.id && isReadableTextMessage(message);
        });
      for (const message of availableMessages) {
        if (!hasCapturedMessage.get(message.id._serialized)) continue;
        const sender = await senderLabel(message);
        const senderId = message.fromMe ? 'me' : (message.author || message.from);
        if (senderId !== 'me' && sender && !sender.endsWith('@lid')) {
          updateMessageSender.run(sender, message.id._serialized);
        }
      }
        const typeSummary = new Map();
        for (const message of availableMessages) {
          const key = `${message.type}${isToday(message.timestamp) ? ' (today)' : ''}${isPollMessage(message) ? ' [poll]' : ''}`;
          typeSummary.set(key, (typeSummary.get(key) || 0) + 1);
        }
        console.log(`Group history types: ${[...typeSummary.entries()].map(([type, count]) => `${type}: ${count}`).join('; ') || 'none'}`);
        let selectedMessages;
        const votesByPollId = new Map();
        if (readChoice === '1') {
          selectedMessages = availableMessages.filter((message) =>
            message.type === 'chat' && isToday(message.timestamp));
          const polls = availableMessages.filter(isPollMessage);
          for (const poll of polls) {
            let votes = [];
            try {
              votes = await client.getPollVotes(poll.id._serialized);
              for (const vote of votes || []) {
                captureVote(vote, selection.id, vote.voter ? await voterLabel(vote.voter) : null);
              }
            } catch (error) {
              if (isToday(poll.timestamp)) {
                console.log(`Could not load votes for poll "${poll.pollName || poll.body}": ${error.message || error}`);
              }
            }
            const hasVoteActivityToday = votes.some((vote) => isTodayMilliseconds(vote.interractedAtTs));
            if (isToday(poll.timestamp) || hasVoteActivityToday) {
              selectedMessages.push(poll);
              votesByPollId.set(poll.id._serialized, votes);
            }
          }
          selectedMessages.sort((a, b) => a.timestamp - b.timestamp);
          console.log(`Found ${selectedMessages.length} messages for today, including polls created today or updated today.`);
        } else {
          availableMessages.sort((a, b) => b.timestamp - a.timestamp);
          selectedMessages = availableMessages.slice(0, 1);
        }
        let shown = 0;
        let newlySaved = 0;
        for (const message of selectedMessages) {
          const sender = await senderLabel(message);
          if (captureMessage(message, selection.id, sender)) newlySaved++;
          shown++;
          const sentAt = new Date(message.timestamp * 1000).toISOString();
          console.log(`[${sentAt}] ${sender}: ${displayMessage(message)}`);
          await printMessageReactions(await readMessageReactions(message, selection.id));
          if (isPollMessage(message)) {
            try {
              const votes = votesByPollId.get(message.id._serialized) ||
                await client.getPollVotes(message.id._serialized);
              await printPollVotes(votes, selection.id);
            } catch (error) {
              console.log(`  Vote details unavailable: ${error.message || error}`);
            }
          }
        }
        console.log(`Displayed ${shown} available message(s); saved ${newlySaved} new message(s).`);
      }
      if (appMode && selection) await cacheGroupHistory(selection);
      if (selection) console.log(`Listening only to ${selection.name}.`);
      else console.log('Connected. Select a group in the RKAVIC app to begin reading.');
      emitAppEvent({ type: 'reader_ready', selectedGroup: selection?.id || null });
      if (!appMode) {
        try { fs.rmSync(selectionRequestPath, { force: true }); } catch (_) { /* No pending request. */ }
      }
      let switchingGroup = false;
      const applySelectionRequest = async () => {
        if (switchingGroup) return;
        if (!fs.existsSync(selectionRequestPath)) return;
        switchingGroup = true;
        try {
          const request = JSON.parse(fs.readFileSync(selectionRequestPath, 'utf8'));
          const group = groups.find((candidate) => candidate.id._serialized === request.id);
          if (!group || group.id._serialized === selection?.id) return;
          selection = { id: group.id._serialized, name: group.name };
          writeJsonAtomic(selectionPath, selection);
          emitAppEvent({ type: 'group_selected', id: selection.id, name: selection.name });
          console.log(`App selected group: ${selection.name}`);
          await cacheGroupHistory(selection);
        } catch (error) {
          console.error(`Could not switch selected group: ${error.message || error}`);
        } finally {
          switchingGroup = false;
        }
      };
      fs.watchFile(selectionRequestPath, { interval: 750 }, (current, previous) => {
        if (current.mtimeMs === 0 || current.mtimeMs === previous.mtimeMs) return;
        void applySelectionRequest();
      });
      if (appMode) void applySelectionRequest();
      client.on('message', async (message) => {
        const activeSelection = selection;
        const chatId = message.fromMe ? message.to : message.from;
        if (!activeSelection || chatId !== activeSelection.id) return;
        const sender = await senderLabel(message);
        if (captureMessage(message, activeSelection.id, sender)) {
          const sentAt = new Date(message.timestamp * 1000).toISOString();
          console.log(`[${sentAt}] ${sender}: ${displayMessage(message)}`);
        }
      });
      client.on('vote_update', async (vote) => {
        const activeSelection = selection;
        if (!activeSelection) return;
        const name = vote.voter ? await voterLabel(vote.voter) : null;
        if (captureVote(vote, activeSelection.id, name)) {
          const choices = (vote.selectedOptions || []).map((option) => option.name).join(', ') || '(no options selected)';
          console.log(`[${new Date(vote.interractedAtTs || Date.now()).toISOString()}] Poll vote by ${name || 'Unknown participant'}: ${choices}`);
        }
      });
      client.on('message_reaction', async (reaction) => {
        const activeSelection = selection;
        if (!activeSelection) return;
        const parentKey = reaction.msgId;
        const messageId = normalizedId(parentKey);
        const remote = normalizedId(parentKey?.remote) || parentKey?.remote;
        if (!messageId || remote !== activeSelection.id) return;
        const senderId = reaction.senderId || normalizedId(parentKey?.participant) || parentKey?.participant;
        const who = client.info?.wid?._serialized === senderId || client.info?.wid?.$1 === senderId
          ? 'you'
          : await voterLabel(senderId);
        if (!captureReaction(messageId, activeSelection.id, senderId, reaction.reaction, reaction.timestamp, who)) return;
        let target = `message ${messageId}`;
        try {
          const parentMessage = await client.getMessageById(messageId);
          if (parentMessage) {
            const targetSender = await senderLabel(parentMessage);
            target = `${targetSender}: ${displayMessage(parentMessage).replace(/\s+/g, ' ').slice(0, 100)}`;
          }
        } catch (_) { /* Keep the message ID when WhatsApp cannot reload the parent. */ }
        if (reaction.reaction) {
          console.log(`Reaction update: ${who} reacted ${reaction.reaction} to ${target}`);
        } else {
          console.log(`Reaction removed: ${who} from ${target}`);
        }
      });
      if (!appMode) await sendLoop(() => selection);
    } catch (error) {
      console.error(`Could not load groups: ${error.message}`);
    }
  });
  emitAppEvent({ type: 'reader_starting' });
  await client.initialize();
}

process.once('SIGINT', () => shutdown().finally(() => process.exit(0)));
process.once('SIGTERM', () => shutdown().finally(() => process.exit(0)));
main().catch(async (error) => {
  console.error(`Reader stopped: ${error.message}`);
  await shutdown();
  process.exitCode = 1;
});
