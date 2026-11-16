'use strict';

function groupId(group) {
  const id = group?.id;
  return typeof id === 'string' ? id : id?._serialized || id?.$1 || '';
}

function groupName(group) {
  const candidates = [group?.name, group?.groupMetadata?.subject, group?.groupMetadata?.name];
  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate.trim()) return candidate.trim();
  }
  return `Unnamed group (${groupId(group) || 'unknown ID'})`;
}

function listGroups(chats) {
  return chats.filter((chat) => chat?.isGroup && groupId(chat)).map((group) => ({
    id: groupId(group),
    name: groupName(group),
  })).sort((left, right) => left.name.localeCompare(right.name));
}

module.exports = { groupId, groupName, listGroups };
