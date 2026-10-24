// Exercise the shipped JXA command with a fake Music app. Never sends Apple events.
ObjC.import('Foundation');
function run(argv) {
    var source = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null));
    function check(value, message) { if (!value) throw new Error(message); }
    var a = '0000000000000001', b = '0000000000000002', missing = '0000000000000003', c = '0000000000000004';
    function scenario(request, options) {
        options = options || {};
        var played = [], queried = [], launched = false, waits = 0, selected, made = [], deleted = [], currentPlaylist = '', revealed = [];
        var shuffle = true, repeat = 'one', position = 93;
        function track(id, number) {
            return {persistentID: id, title: 'Same title', albumArtist: function () { return options.wrongArtist ? 'Guest' : 'Album artist'; },
                album: function () { return 'Album'; }, discNumber: function () { return options.savedSubset ? (number === 1 ? 2 : 3) : 1; }, discCount: function () { return options.savedSubset ? 3 : 1; },
                trackNumber: function () { return options.savedSubset ? (number === 1 ? 4 : 7) : number; }, trackCount: function () { return options.savedSubset ? 12 : 2; }};
        }
        var first = track(a, 1), second = track(b, 2), extra = track(c, 1);
        var old = { persistentID: function () { return 'OLD'; }, description: function () { return options.foreignPlaylist ? 'User playlist' : 'Managed by AM Track: owner'; }};
        var music = {
            running: function () { return !options.closed; },
            launch: function () { launched = true; },
            activate: function () { throw new Error('Queue preparation must not activate Music'); },
            reveal: function (item) { revealed.push(item.persistentID); },
            selection: function () { return options.selectionFailed ? [] : [{persistentID: function () { return options.wrongSelection ? a : revealed[revealed.length - 1]; }}]; },
            libraryPlaylists: [{tracks: {whose: function (filter) {
                queried.push(filter.persistentID);
                if (options.denied) throw new Error('Automation denied (-1743)');
                var matches = [first, second, extra].filter(function (t) { return t.persistentID === filter.persistentID && !(options.missingSecond && t === second); });
                matches.persistentID = function () { return matches.map(function (t) { return t.persistentID; }); };
                return matches;
            }}}],
            make: function () { throw new Error('Message not understood (-1708): create a UserPlaylist object and call its make method'); },
            UserPlaylist: function (properties) {
                var playlist = {properties: properties, queued: [], persistentID: function () { return 'NEW'; }};
                playlist.make = function () { made.push(playlist); };
                playlist.tracks = {persistentID: function () { var ids = playlist.queued.map(function (t) { return t.persistentID; });return options.reverseQueue ? ids.reverse() : ids; }};
                return playlist;
            },
            duplicate: function (t, spec) { spec.to.queued.push(t); },
            delete: function (playlist) { deleted.push(playlist.persistentID()); },
            playlists: {whose: function () { var rows = [old];rows.persistentID = function () { return ['OLD']; };return rows; }},
            play: function (item) {
                played.push(item);
                selected = item.queued ? item.queued[0] : item;
                currentPlaylist = item.queued ? item.persistentID() : '';
            },
            playerState: function () { return options.unavailable ? 'paused' : 'playing'; },
            currentTrack: {persistentID: function () { return options.wrongTrack ? a : selected.persistentID; }},
            currentPlaylist: {persistentID: function () { return currentPlaylist; }}
        };
        Object.defineProperty(music, 'shuffleEnabled', {get: function () { return function () { return shuffle; }; }, set: function (value) { shuffle = value; }});
        Object.defineProperty(music, 'songRepeat', {get: function () { return function () { return repeat; }; }, set: function (value) { repeat = value; }});
        Object.defineProperty(music, 'playerPosition', {get: function () { return function () { return position; }; }, set: function (value) { position = value; }});
        var command = new Function('Application', 'delay', source + '\nreturn run;')(
            function (name) { check(name === 'com.apple.Music', 'wrong target app'); return music; }, function () { waits++; }
        );
        var response, error;
        try { response = JSON.parse(command([JSON.stringify(request)])); } catch (e) { error = e; }
        return {response: response, error: error, played: played, queried: queried, launched: launched, waits: waits, made: made, deleted: deleted, shuffle: shuffle, repeat: repeat, position: position, revealed: revealed};
    }
    var exact = scenario([b]);
    check(exact.response.status === 'playing' && exact.played[0].persistentID === b, 'must play the exact version, not its same-title sibling');
    check(scenario([b], {closed: true}).launched, 'closed Music must be launched');
    var fallback = scenario([missing, b]);
    check(fallback.played.length === 1 && fallback.response.persistent_id === b, 'must try other exact aliases when one was removed');
    var absent = scenario([missing]);
    check(absent.response.status === 'not_found' && absent.played.length === 0, 'missing library track must not trigger generic play');
    [[], ['bad-id'], [a + '\n'], [7], [a, 'bad-id']].forEach(function (ids) {
        var invalid = scenario(ids);
        check(invalid.response.status === 'invalid_id' && invalid.played.length === 0 && invalid.queried.length === 0, 'invalid IDs must not access Music');
    });
    var stalled = scenario([b], {unavailable: true});
    check(stalled.response.status === 'unavailable' && stalled.waits === 24, 'unavailable track must finish with bounded feedback');
    check(scenario([b], {wrongTrack: true}).response.status === 'unavailable', 'wrong current track must not confirm playback');
    check(String(scenario([b], {denied: true}).error).indexOf('1743') >= 0, 'permission denial must reach the app error handler');
    function album() {
        return {kind: 'album', album: 'Album', album_artist: 'Album artist', owner: 'owner', previous_playlist_id: 'OLD', tracks: [
            {ids: [a], disc: 1, discs: 1, number: 1, count: 2}, {ids: [b], disc: 1, discs: 1, number: 2, count: 2}
        ]};
    }
    var withFollowing = album();withFollowing.following_tracks = [{kind: 'song', ids: [c]}];
    var continued = scenario(withFollowing);
    check(!continued.error && continued.response.track_count === 2 && continued.response.following_ids.join(',') === c &&
        continued.played[0].queued.map(function (t) { return t.persistentID; }).join(',') === [a,b,c].join(','),
        'album queue is assembled with individual follow-ups strictly after the complete album before playback starts');
    var missingFollowing = album();missingFollowing.following_tracks = [{kind: 'song', ids: [missing]}, {kind: 'song', ids: [c]}];
    var short = scenario(missingFollowing);
    check(!short.error && short.response.status === 'playing' && short.response.following_ids.length === 0 && short.played[0].queued.length === 2,
        'unavailable follow-ups preserve complete album playback and report only the confirmed prefix');
    var duplicateFollowing = album();duplicateFollowing.following_tracks = [{kind: 'song', ids: [a]}];
    check(scenario(duplicateFollowing).response.following_ids.length === 0, 'album tracks cannot repeat as automatic follow-ups');
    var badFollowing = album();badFollowing.following_tracks = [{kind: 'album', ids: [c]}];
    check(scenario(badFollowing).response.status === 'invalid_id', 'automatic album follow-ups must be individual songs');
    var whole = scenario(album());
    check(!whole.error && whole.response.from_start && whole.response.persistent_id === a && whole.response.track_count === 2, 'whole album starts with its first track');
    check(whole.made.length === 1 && whole.played[0].queued[1].persistentID === b, 'native playlist contains the next album track in order');
    check(!whole.shuffle && whole.repeat === 'off' && whole.position === 0, 'album playback disables shuffle and repeat and resets to zero');
    check(whole.deleted.join(',') === 'OLD', 'only the previous owned playlist is cleaned up');
    var subset = album();
    subset.tracks = [{ids: [a], disc: 2, discs: 3, number: 4, count: 12}, {ids: [b], disc: 3, discs: 3, number: 7, count: 12}];
    var saved = scenario(subset, {savedSubset: true});
    check(!saved.error && saved.response.status === 'playing' && saved.response.track_count === 2 && saved.position === 0,
        'saved subset plays from its first saved track even when opening songs and discs are unsaved');
    check(saved.played[0].queued.map(function (t) { return t.persistentID; }).join(',') === [a, b].join(','), 'only saved subset tracks enter the queue, in disc/track order');
    var duplicatePosition = album();duplicatePosition.tracks[1].number = 1;
    check(scenario(duplicatePosition).response.status === 'invalid_album', 'duplicate saved positions are rejected');
    check(scenario(album(), {foreignPlaylist: true}).deleted.length === 0, 'a user playlist is never deleted even with the same supplied ID');
    var incomplete = scenario(album(), {missingSecond: true});
    check(incomplete.response.status === 'incomplete_album' && incomplete.made.length === 0 && incomplete.played.length === 0, 'all album tracks are checked before any playlist or playback mutation');
    check(scenario(album(), {wrongArtist: true}).response.status === 'incomplete_album', 'song artist cannot substitute for the album artist');
    var invalidAlbum = album();invalidAlbum.tracks.reverse();
    check(scenario(invalidAlbum).response.status === 'invalid_album', 'unsorted requests cannot start an album from a middle track');
    var dry = album();dry.validate_only = true;
    var validated = scenario(dry);
    check(validated.response.status === 'validated' && validated.made.length === 0 && validated.played.length === 0, 'read-only album validation does not change Music');
    check(validated.response.persistent_ids.join(',') === [a,b].join(','), 'queue preflight returns every exact album ID in saved order');
    var queueDry = album();queueDry.validate_queue_only = true;
    var queueChecked = scenario(queueDry);
    check(queueChecked.response.status === 'queue_validated' && queueChecked.played.length === 0 && queueChecked.deleted.join(',') === 'NEW' && queueChecked.shuffle && queueChecked.repeat === 'one', 'queue validation removes only the scratch playlist and never changes playback or modes');
    var badOrder = scenario(album(), {reverseQueue: true});
    check(badOrder.error && badOrder.played.length === 0 && badOrder.deleted.join(',') === 'NEW', 'unexpected native playlist order is rejected before playback and the scratch playlist is removed');
    var stalledAlbum = scenario(album(), {unavailable: true});
    check(stalledAlbum.error && stalledAlbum.waits === 24 && stalledAlbum.shuffle && stalledAlbum.repeat === 'one' && stalledAlbum.deleted.join(',') === 'NEW', 'failed album start restores playback modes and cleans the scratch playlist');
    return 'PASS: song identity, aliases, missing IDs, permission errors; album completeness, first-track start, full album and one-follow-up order, shuffle/repeat, owned-playlist cleanup and read-only validation. No Music playback triggered.';
}
