'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { listGroups } = require('../src/groups');

test('group discovery handles missing names and IDs without losing named groups', () => {
  const groups = listGroups([
    { isGroup: true, id: { _serialized: '1@g.us' }, name: 'Team' },
    { isGroup: true, id: { _serialized: '2@g.us' }, groupMetadata: { subject: 'Family' } },
    { isGroup: true, id: { _serialized: '3@g.us' } },
    { isGroup: true, id: { _serialized: '4@g.us' }, name: null },
    { isGroup: true, name: 'Missing ID' },
    { isGroup: false, id: { _serialized: 'person' }, name: 'Private chat' },
  ]);

  assert.deepEqual(groups, [
    { id: '2@g.us', name: 'Family' },
    { id: '1@g.us', name: 'Team' },
    { id: '3@g.us', name: 'Unnamed group (3@g.us)' },
    { id: '4@g.us', name: 'Unnamed group (4@g.us)' },
  ]);
});
