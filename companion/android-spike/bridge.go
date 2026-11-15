package bridge

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

const maxCachedMessages = 5000

type pollOption struct {
	Name string `json:"name"`
	Hash string `json:"hash"`
}

type pollVote struct {
	VoterID string    `json:"voterId"`
	Voter   string    `json:"voter"`
	Options []string  `json:"options"`
	Hashes  []string  `json:"hashes,omitempty"`
	At      time.Time `json:"at"`
}

type reaction struct {
	SenderID string    `json:"senderId"`
	Sender   string    `json:"sender"`
	Emoji    string    `json:"emoji"`
	At       time.Time `json:"at"`
}

type readerMessage struct {
	ID        string       `json:"id"`
	Chat      string       `json:"chat"`
	SenderID  string       `json:"senderId"`
	Sender    string       `json:"sender"`
	FromMe    bool         `json:"fromMe"`
	Timestamp time.Time    `json:"timestamp"`
	Kind      string       `json:"kind"`
	Text      string       `json:"text"`
	Options   []pollOption `json:"options,omitempty"`
	Votes     []pollVote   `json:"votes,omitempty"`
	Reactions []reaction   `json:"reactions,omitempty"`
}

// Listener is an experimental Android-callable WhatsApp linked-device client.
type Listener struct {
	mu            sync.Mutex
	client        *whatsmeow.Client
	container     *sqlstore.Container
	cancel        context.CancelFunc
	ctx           context.Context
	events        chan string
	qrReady       chan struct{}
	qrOnce        sync.Once
	selectedGroup string
	messages      map[string]*readerMessage
	messageOrder  []string
	votes         map[string]map[string]pollVote
	reactions     map[string]map[string]reaction
	cachePath     string
}

func NewListener() *Listener {
	return &Listener{
		events: make(chan string, 128), qrReady: make(chan struct{}),
		messages: make(map[string]*readerMessage), votes: make(map[string]map[string]pollVote),
		reactions: make(map[string]map[string]reaction),
	}
}

func (l *Listener) emit(value any) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return
	}
	select {
	case l.events <- string(encoded):
	default:
	}
}

// Start initializes a private SQLite session store and starts pairing or reconnecting.
func (l *Listener) Start(databasePath string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.client != nil {
		return fmt.Errorf("listener already started")
	}
	ctx, cancel := context.WithCancel(context.Background())
	address := "file:" + databasePath + "?_foreign_keys=on"
	container, err := sqlstore.New(ctx, "sqlite3", address, nil)
	if err != nil {
		cancel()
		return err
	}
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		container.Close()
		cancel()
		return err
	}
	client := whatsmeow.NewClient(device, nil)
	l.container, l.client, l.cancel, l.ctx = container, client, cancel, ctx
	l.cachePath = databasePath + ".reader.json"
	l.loadCacheLocked()
	var qrEvents <-chan whatsmeow.QRChannelItem
	if device.GetJID().IsEmpty() {
		qrEvents, err = client.GetQRChannel(ctx)
		if err != nil {
			container.Close()
			cancel()
			l.client = nil
			return err
		}
	}
	client.AddEventHandler(func(evt any) {
		switch e := evt.(type) {
		case *events.Connected:
			l.emit(map[string]any{"type": "connected"})
		case *events.Disconnected:
			l.emit(map[string]any{"type": "disconnected"})
		case *events.OfflineSyncCompleted:
			l.emit(map[string]any{"type": "history_sync_complete"})
		case *events.HistorySync:
			l.processHistorySync(client, ctx, e)
		case *events.Message:
			l.processMessage(client, ctx, e, true)
		}
	})
	if qrEvents != nil {
		go func() {
			for item := range qrEvents {
				if item.Code != "" {
					l.qrOnce.Do(func() { close(l.qrReady) })
				}
				l.emit(map[string]any{"type": "pairing", "code": item.Code, "error": item.Error})
			}
		}()
	}
	if err := client.Connect(); err != nil {
		cancel()
		container.Close()
		l.client = nil
		return err
	}
	l.emit(map[string]any{"type": "started"})
	return nil
}

// SetGroup limits visible reader results and live events to one selected group.
func (l *Listener) SetGroup(groupID string) {
	l.mu.Lock()
	l.selectedGroup = groupID
	l.persistLocked()
	l.mu.Unlock()
}

// PairPhone requests a WhatsApp linked-device code after the server is ready.
func (l *Listener) PairPhone(phoneNumber string) string {
	l.mu.Lock()
	client, ctx := l.client, l.ctx
	l.mu.Unlock()
	if client == nil {
		encoded, _ := json.Marshal(map[string]string{"type": "pairing_error", "error": "listener is not started"})
		return string(encoded)
	}
	if client.IsLoggedIn() {
		encoded, _ := json.Marshal(map[string]string{"type": "pairing_error", "error": "This device is already linked. Load groups instead."})
		return string(encoded)
	}
	select {
	case <-l.qrReady:
	case <-ctx.Done():
		return `{"type":"pairing_error","error":"listener stopped"}`
	}
	code, err := client.PairPhone(ctx, phoneNumber, true, whatsmeow.PairClientChrome, "Chrome (Android)")
	if err != nil {
		encoded, _ := json.Marshal(map[string]string{"type": "pairing_error", "error": err.Error()})
		return string(encoded)
	}
	encoded, _ := json.Marshal(map[string]string{"type": "pairing_code", "code": code})
	l.emit(map[string]string{"type": "pairing_code", "code": code})
	return string(encoded)
}

func (l *Listener) NextEvent() string { return <-l.events }

func (l *Listener) Groups() string {
	l.mu.Lock()
	client := l.client
	l.mu.Unlock()
	if client == nil {
		return "[]"
	}
	groups, err := client.GetJoinedGroups(context.Background())
	if err != nil {
		return "[]"
	}
	result := make([]map[string]string, 0, len(groups))
	for _, group := range groups {
		result = append(result, map[string]string{"id": group.JID.String(), "name": group.Name})
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return "[]"
	}
	return string(encoded)
}

// ReadToday returns text messages from today and polls created or voted on today.
func (l *Listener) ReadToday() string { return l.historyResult("today") }

// ReadLatest returns the newest message, including current poll votes and reactions.
func (l *Listener) ReadLatest() string { return l.historyResult("latest") }

func (l *Listener) historyResult(mode string) string {
	l.mu.Lock()
	group := l.selectedGroup
	items := make([]readerMessage, 0, len(l.messages))
	for _, id := range l.messageOrder {
		message := l.messages[id]
		if message != nil && message.Chat == group {
			copy := *message
			copy.Votes = l.votesForLocked(id)
			copy.Reactions = l.reactionsForLocked(id)
			items = append(items, copy)
		}
	}
	l.mu.Unlock()

	if group == "" {
		return `{"type":"history_result","error":"Select a group first.","messages":[]}`
	}
	groupCachedCount := len(items)
	sort.Slice(items, func(i, j int) bool { return items[i].Timestamp.Before(items[j].Timestamp) })
	if mode == "latest" {
		if len(items) > 0 {
			latest := items[len(items)-1]
			items = []readerMessage{latest}
		}
	} else {
		today := time.Now().In(time.Local).Format("2006-01-02")
		filtered := make([]readerMessage, 0, len(items))
		for _, item := range items {
			createdToday := item.Timestamp.In(time.Local).Format("2006-01-02") == today
			voteToday := false
			for _, vote := range item.Votes {
				if vote.At.In(time.Local).Format("2006-01-02") == today {
					voteToday = true
					break
				}
			}
			if createdToday && item.Kind != "reaction" && item.Kind != "poll_vote" || item.Kind == "poll" && voteToday {
				filtered = append(filtered, item)
			}
		}
		items = filtered
	}
	result := map[string]any{"type": "history_result", "mode": mode, "messages": items, "cachedGroupMessages": groupCachedCount}
	if len(items) == 0 {
		if groupCachedCount == 0 {
			result["error"] = "This Android linked session has no saved messages for this group. It only receives history WhatsApp syncs when linking and messages received while the listener is running."
		} else if mode == "today" {
			result["error"] = "No messages from today are in this group's synced history yet."
		} else {
			result["error"] = "No messages are in this group's synced history yet."
		}
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		return `{"type":"history_result","error":"Could not encode reader history.","messages":[]}`
	}
	return string(encoded)
}

func (l *Listener) processHistorySync(client *whatsmeow.Client, ctx context.Context, syncEvent *events.HistorySync) {
	if syncEvent.Data == nil {
		return
	}
	count := 0
	for _, conversation := range syncEvent.Data.GetConversations() {
		chat, err := types.ParseJID(conversation.GetID())
		if err != nil {
			continue
		}
		for _, historyMessage := range conversation.GetMessages() {
			if historyMessage.GetMessage() == nil {
				continue
			}
			parsed, err := client.ParseWebMessage(chat, historyMessage.GetMessage())
			if err != nil || parsed == nil {
				continue
			}
			l.processMessage(client, ctx, parsed, false)
			count++
		}
	}
	l.mu.Lock()
	l.persistLocked()
	l.mu.Unlock()
	l.emit(map[string]any{"type": "history_sync", "messages": count})
}

func (l *Listener) resolveName(client *whatsmeow.Client, jid types.JID, pushName string) string {
	if jid.IsEmpty() {
		return "member"
	}
	if pushName = strings.TrimSpace(pushName); pushName != "" {
		return pushName
	}
	ctx := context.Background()
	contact, err := client.Store.Contacts.GetContact(ctx, jid)
	if err == nil {
		for _, name := range []string{contact.FullName, contact.FirstName, contact.PushName, contact.BusinessName} {
			if strings.TrimSpace(name) != "" {
				return strings.TrimSpace(name)
			}
		}
	}
	if jid.Server == types.HiddenUserServer {
		if phone, mapErr := client.Store.LIDs.GetPNForLID(ctx, jid); mapErr == nil && !phone.IsEmpty() {
			contact, err = client.Store.Contacts.GetContact(ctx, phone)
			if err == nil {
				for _, name := range []string{contact.FullName, contact.FirstName, contact.PushName, contact.BusinessName} {
					if strings.TrimSpace(name) != "" {
						return strings.TrimSpace(name)
					}
				}
			}
			return phone.User
		}
	}
	return jid.User
}

func messageText(message *events.Message) string {
	if message == nil || message.Message == nil {
		return ""
	}
	if text := strings.TrimSpace(message.Message.GetConversation()); text != "" {
		return text
	}
	if extended := message.Message.GetExtendedTextMessage(); extended != nil {
		return strings.TrimSpace(extended.GetText())
	}
	return ""
}

func (l *Listener) processMessage(client *whatsmeow.Client, ctx context.Context, event *events.Message, emitLive bool) {
	if event == nil || event.Message == nil {
		return
	}
	chatID := event.Info.Chat.String()
	senderID := event.Info.Sender.String()
	sender := "you"
	if !event.Info.IsFromMe {
		sender = l.resolveName(client, event.Info.Sender, event.Info.PushName)
	}
	message := event.Message
	if poll := message.GetPollCreationMessage(); poll != nil {
		options := make([]pollOption, 0, len(poll.GetOptions()))
		for _, option := range poll.GetOptions() {
			options = append(options, pollOption{Name: option.GetOptionName(), Hash: option.GetOptionHash()})
		}
		item := &readerMessage{ID: event.Info.ID, Chat: chatID, SenderID: senderID, Sender: sender, FromMe: event.Info.IsFromMe, Timestamp: event.Info.Timestamp, Kind: "poll", Text: poll.GetName(), Options: options}
		l.saveMessage(item, emitLive)
		return
	}
	if update := message.GetPollUpdateMessage(); update != nil {
		vote, err := client.DecryptPollVote(ctx, event)
		if err != nil {
			if emitLive {
				l.emit(map[string]any{"type": "poll_vote_error", "error": err.Error()})
			}
			return
		}
		pollID := update.GetPollCreationMessageKey().GetID()
		selectedHashes := make(map[string]bool, len(vote.GetSelectedOptions()))
		for _, hash := range vote.GetSelectedOptions() {
			selectedHashes[hex.EncodeToString(hash)] = true
			selectedHashes[base64.StdEncoding.EncodeToString(hash)] = true
			selectedHashes[string(hash)] = true
		}
		hashValues := make([]string, 0, len(vote.GetSelectedOptions()))
		for _, hash := range vote.GetSelectedOptions() {
			hashValues = append(hashValues, hex.EncodeToString(hash))
		}
		l.mu.Lock()
		poll := l.messages[pollID]
		selected := make([]string, 0)
		if poll != nil {
			for _, option := range poll.Options {
				if selectedHashes[option.Hash] {
					selected = append(selected, option.Name)
				}
			}
		}
		if l.votes[pollID] == nil {
			l.votes[pollID] = make(map[string]pollVote)
		}
		voteRecord := pollVote{VoterID: senderID, Voter: sender, Options: selected, Hashes: hashValues, At: event.Info.Timestamp}
		l.votes[pollID][senderID] = voteRecord
		group := l.selectedGroup
		var snapshot *readerMessage
		if poll != nil {
			copy := *poll
			copy.Votes = l.votesForLocked(pollID)
			copy.Reactions = l.reactionsForLocked(pollID)
			snapshot = &copy
		}
		if emitLive && chatID == group {
			l.persistLocked()
		}
		l.mu.Unlock()
		if emitLive && chatID == group {
			l.emit(map[string]any{"type": "poll_vote", "message": snapshot, "voter": voteRecord})
		}
		return
	}
	if reactionMessage := message.GetReactionMessage(); reactionMessage != nil {
		l.saveReaction(client, event, reactionMessage.GetKey().GetID(), reactionMessage.GetText(), emitLive)
		return
	}
	if message.GetEncReactionMessage() != nil {
		decrypted, err := client.DecryptReaction(ctx, event)
		if err == nil && decrypted != nil {
			l.saveReaction(client, event, decrypted.GetKey().GetID(), decrypted.GetText(), emitLive)
		}
		return
	}
	if text := messageText(event); text != "" {
		l.saveMessage(&readerMessage{ID: event.Info.ID, Chat: chatID, SenderID: senderID, Sender: sender, FromMe: event.Info.IsFromMe, Timestamp: event.Info.Timestamp, Kind: "message", Text: text}, emitLive)
	}
}

func (l *Listener) saveMessage(item *readerMessage, emitLive bool) {
	l.mu.Lock()
	if _, exists := l.messages[item.ID]; !exists {
		l.messageOrder = append(l.messageOrder, item.ID)
	}
	l.messages[item.ID] = item
	if item.Kind == "poll" {
		for voterID, vote := range l.votes[item.ID] {
			vote.Options = optionNamesForHashes(item.Options, vote.Hashes)
			l.votes[item.ID][voterID] = vote
		}
	}
	for len(l.messageOrder) > maxCachedMessages {
		oldest := l.messageOrder[0]
		l.messageOrder = l.messageOrder[1:]
		delete(l.messages, oldest)
		delete(l.votes, oldest)
		delete(l.reactions, oldest)
	}
	selected := l.selectedGroup
	copy := *item
	copy.Votes = l.votesForLocked(item.ID)
	copy.Reactions = l.reactionsForLocked(item.ID)
	if emitLive && item.Chat == selected {
		l.persistLocked()
	}
	l.mu.Unlock()
	if emitLive && item.Chat == selected {
		l.emit(map[string]any{"type": "reader_message", "message": copy})
	}
}

func (l *Listener) saveReaction(client *whatsmeow.Client, event *events.Message, messageID, emoji string, emitLive bool) {
	if messageID == "" {
		return
	}
	reactionRecord := reaction{SenderID: event.Info.Sender.String(), Sender: l.resolveName(client, event.Info.Sender, event.Info.PushName), Emoji: emoji, At: event.Info.Timestamp}
	l.mu.Lock()
	if l.reactions[messageID] == nil {
		l.reactions[messageID] = make(map[string]reaction)
	}
	if emoji == "" {
		delete(l.reactions[messageID], reactionRecord.SenderID)
	} else {
		l.reactions[messageID][reactionRecord.SenderID] = reactionRecord
	}
	group := l.selectedGroup
	item := l.messages[messageID]
	var snapshot *readerMessage
	if item != nil {
		copy := *item
		copy.Votes = l.votesForLocked(messageID)
		copy.Reactions = l.reactionsForLocked(messageID)
		snapshot = &copy
	}
	if emitLive && event.Info.Chat.String() == group {
		l.persistLocked()
	}
	l.mu.Unlock()
	if emitLive && event.Info.Chat.String() == group {
		l.emit(map[string]any{"type": "reaction", "message": snapshot, "reaction": reactionRecord})
	}
}

func (l *Listener) votesForLocked(pollID string) []pollVote {
	votes := make([]pollVote, 0, len(l.votes[pollID]))
	for _, vote := range l.votes[pollID] {
		votes = append(votes, vote)
	}
	sort.Slice(votes, func(i, j int) bool { return votes[i].At.Before(votes[j].At) })
	return votes
}

func (l *Listener) reactionsForLocked(messageID string) []reaction {
	items := make([]reaction, 0, len(l.reactions[messageID]))
	for _, value := range l.reactions[messageID] {
		items = append(items, value)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].At.Before(items[j].At) })
	return items
}

func optionNamesForHashes(options []pollOption, hashes []string) []string {
	selected := make(map[string]bool, len(hashes))
	for _, hash := range hashes {
		selected[hash] = true
	}
	names := make([]string, 0, len(hashes))
	for _, option := range options {
		if selected[option.Hash] || selected[strings.ToLower(option.Hash)] {
			names = append(names, option.Name)
		}
	}
	return names
}

type persistedReaderState struct {
	Messages []readerMessage `json:"messages"`
}

func (l *Listener) loadCacheLocked() {
	data, err := os.ReadFile(l.cachePath)
	if err != nil {
		return
	}
	var saved persistedReaderState
	if json.Unmarshal(data, &saved) != nil {
		return
	}
	cutoff := time.Now().AddDate(0, 0, -30)
	for _, item := range saved.Messages {
		if item.ID == "" || item.Timestamp.Before(cutoff) {
			continue
		}
		copy := item
		l.messages[item.ID] = &copy
		l.messageOrder = append(l.messageOrder, item.ID)
		if len(item.Votes) > 0 {
			l.votes[item.ID] = make(map[string]pollVote, len(item.Votes))
			for _, vote := range item.Votes {
				l.votes[item.ID][vote.VoterID] = vote
			}
		}
		if len(item.Reactions) > 0 {
			l.reactions[item.ID] = make(map[string]reaction, len(item.Reactions))
			for _, value := range item.Reactions {
				l.reactions[item.ID][value.SenderID] = value
			}
		}
	}
	if len(l.messageOrder) > maxCachedMessages {
		l.messageOrder = l.messageOrder[len(l.messageOrder)-maxCachedMessages:]
	}
}

func (l *Listener) persistLocked() {
	if l.cachePath == "" || l.selectedGroup == "" {
		return
	}
	cutoff := time.Now().AddDate(0, 0, -30)
	items := make([]readerMessage, 0, len(l.messages))
	keptIDs := make([]string, 0, len(l.messageOrder))
	for _, id := range l.messageOrder {
		item := l.messages[id]
		if item == nil || item.Timestamp.Before(cutoff) {
			delete(l.messages, id)
			delete(l.votes, id)
			delete(l.reactions, id)
			continue
		}
		keptIDs = append(keptIDs, id)
		if item.Chat != l.selectedGroup {
			continue
		}
		copy := *item
		copy.Votes = l.votesForLocked(id)
		copy.Reactions = l.reactionsForLocked(id)
		items = append(items, copy)
	}
	if len(keptIDs) > maxCachedMessages {
		keptIDs = keptIDs[len(keptIDs)-maxCachedMessages:]
		items = items[len(items)-maxCachedMessages:]
	}
	l.messageOrder = keptIDs
	encoded, err := json.Marshal(persistedReaderState{Messages: items})
	if err != nil {
		return
	}
	tempPath := l.cachePath + ".tmp"
	if os.WriteFile(tempPath, encoded, 0600) == nil {
		_ = os.Rename(tempPath, l.cachePath)
	}
}

func (l *Listener) Stop() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.cancel != nil {
		l.cancel()
	}
	if l.client != nil {
		l.client.Disconnect()
		l.client = nil
	}
	if l.container != nil {
		l.container.Close()
		l.container = nil
	}
}
