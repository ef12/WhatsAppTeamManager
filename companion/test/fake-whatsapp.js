'use strict';

const Module = require('node:module');
const { EventEmitter } = require('node:events');
const original = Module._load;
const now = Math.floor(Date.now() / 1000);
const selected = 'test-group@g.us';
const message = { id: { _serialized: 'text-1' }, from: selected, fromMe: false, author: 'person@lid', type: 'chat', body: 'Hello team', timestamp: now };
const poll = { id: { _serialized: 'poll-1' }, from: selected, fromMe: false, author: 'person@lid', type: 'poll_creation', pollName: 'Are you coming?', pollOptions: [{ name: 'Yes' }, { name: 'No' }], allowMultipleAnswers: true, timestamp: now };

class FakeClient extends EventEmitter {
  async initialize() { setTimeout(() => this.emit('ready'), 10); }
  async getChats() { return [{ isGroup: true, id: { _serialized: selected }, name: 'Test team' }]; }
  async getChatById() { return { isGroup: true, fetchMessages: async () => [] }; }
  async getContactById() { return { name: 'Revi' }; }
  async destroy() {}
  trigger() {
    this.emit('message_create', { ...message, id: { _serialized: 'other-message' }, from: 'other-group@g.us' });
    this.emit('message_create', message);
    this.emit('message_create', { ...message, id: { _serialized: 'own-message' }, fromMe: true, from: 'me@c.us', to: selected, body: 'My message' });
    this.emit('message_create', poll);
    setTimeout(() => this.emit('vote_update', { voter: 'person@lid', parentMessage: poll, selectedOptions: [{ name: 'Yes' }], interractedAtTs: Date.now() }), 200);
    setTimeout(() => this.emit('vote_update', { voter: 'person@lid', parentMessage: poll, selectedOptions: [{ name: 'No' }], interractedAtTs: Date.now() }), 350);
    setTimeout(() => this.emit('vote_update', { voter: 'person@lid', parentMessage: poll, selectedOptions: [], interractedAtTs: Date.now() }), 500);
  }
}

Module._load = function(request, parent, isMain) {
  if (request === 'whatsapp-web.js') {
    return { Client: class extends FakeClient { constructor() { super(); setTimeout(() => this.trigger(), 250); } }, LocalAuth: class {} };
  }
  return original.apply(this, arguments);
};
