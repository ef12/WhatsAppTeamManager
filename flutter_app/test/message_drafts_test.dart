import 'package:flutter_test/flutter_test.dart';
import 'package:rkavic_manager/data/message_drafts.dart';
import 'package:rkavic_manager/data/team_store.dart';

void main() {
  const match = TeamMatch(
    1,
    'RKAVIC vs Lions',
    '2026-10-03 10:00',
    '2026-10-03 09:30',
    'Home field',
    '1B2',
    '2026-10-01 18:00',
    null,
    null,
    false,
  );
  const players = [Player(1, 'Sam', 'Alex'), Player(2, 'Jo', '')];

  test('reminder names only players with no response', () {
    final draft = reminderDraft(match, players, {1: 1});
    expect(draft, contains('Jo'));
    expect(draft, isNot(contains('Sam')));
  });

  test('duty draft addresses a parent when available', () {
    final draft = dutiesDraft(match, players, [
      const Duty(4, 'Field setup', 1, false),
    ]);
    expect(draft, contains('Field setup: Alex'));
  });

  test('venue drafts include the field number', () {
    expect(invitationDraft(match), contains('Field: 1B2'));
    expect(substitutesDraft(match), contains('Field: 1B2'));
  });

  test('venue drafts include an encoded Google Maps link', () {
    const addressMatch = TeamMatch(
      2,
      'Away match',
      '2026-10-03 10:00',
      '2026-10-03 09:30',
      'Sportpark De Meern, Utrecht',
      '1B2',
      '2026-10-01 18:00',
      null,
      null,
      false,
    );
    final mapsUri = addressMatch.mapsUri!;
    expect(mapsUri.host, 'www.google.com');
    expect(mapsUri.path, '/maps/search/');
    expect(mapsUri.queryParameters['api'], '1');
    expect(mapsUri.queryParameters['query'], addressMatch.location);
    expect(invitationDraft(addressMatch), contains('Map: $mapsUri'));
    expect(substitutesDraft(addressMatch), contains('Map: $mapsUri'));
  });

  test('a match without an address has no map link', () {
    const noAddress = TeamMatch(
      3,
      'Home match',
      '2026-10-03 10:00',
      '2026-10-03 09:30',
      ' ',
      '1B2',
      '2026-10-01 18:00',
      null,
      null,
      false,
    );
    expect(noAddress.mapsUri, isNull);
    expect(invitationDraft(noAddress), isNot(contains('Map:')));
  });
}
