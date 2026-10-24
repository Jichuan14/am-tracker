// Playback is requested explicitly by the user. All identifiers arrive as JSON data.
function run(argv) {
    var request;
    try { request = JSON.parse(argv[0] || '{}'); } catch (_) { return JSON.stringify({status: 'invalid_id'}); }
    if (Array.isArray(request)) request = {kind: 'song', ids: request};
    function validIDs(ids) {
        return Array.isArray(ids) && ids.length > 0 && ids.every(function (id) {
            return typeof id === 'string' && /^[0-9A-F]{16}$/.test(id) && id.length === 16;
        });
    }
    if (!request || (request.kind !== 'song' && request.kind !== 'album')) return JSON.stringify({status: 'invalid_id'});
    var isAlbum = request.kind === 'album';
    if (!isAlbum && !validIDs(request.ids)) return JSON.stringify({status: 'invalid_id'});
    if (isAlbum) {
        if (typeof request.album !== 'string' || !request.album || typeof request.album_artist !== 'string' || !request.album_artist ||
            typeof request.owner !== 'string' || !request.owner || !Array.isArray(request.tracks) || request.tracks.length < 1) {
            return JSON.stringify({status: 'invalid_album'});
        }
        var previousDisc = 0, previousNumber = 0;
        for (var n = 0; n < request.tracks.length; n++) {
            var item = request.tracks[n];
            if (!item || !validIDs(item.ids) || !Number.isInteger(item.disc) || item.disc < 1 ||
                !Number.isInteger(item.number) || item.number < 1 || item.disc < previousDisc ||
                (item.disc === previousDisc && item.number <= previousNumber)) {
                return JSON.stringify({status: 'invalid_album'});
            }
            previousDisc = item.disc;previousNumber = item.number;
        }
    }
    var music = Application('com.apple.Music');
    if (!music.running()) {
        if (request.validate_only || request.validate_queue_only) return JSON.stringify({status: 'unavailable'});
        music.launch();
    }
    var library = music.libraryPlaylists[0].tracks;
    function find(ids, metadata) {
        for (var i = 0; i < ids.length; i++) {
            var matches = library.whose({persistentID: ids[i]});
            if (matches.persistentID().length !== 1) continue;
            var track = matches[0];
            if (metadata && (track.albumArtist() !== request.album_artist || track.album() !== request.album ||
                track.discNumber() !== metadata.disc || track.discCount() !== metadata.discs ||
                track.trackNumber() !== metadata.number || track.trackCount() !== metadata.count)) continue;
            return {track: track, id: ids[i]};
        }
        return null;
    }
    function confirm(id, playlistID) {
        for (var attempt = 0; attempt < 24; attempt++) {
            if (music.playerState() === 'playing' && music.currentTrack.persistentID() === id &&
                (!playlistID || music.currentPlaylist.persistentID() === playlistID)) return true;
            delay(0.25);
        }
        return false;
    }
    if (!isAlbum) {
        var chosen = find(request.ids);
        if (!chosen) return JSON.stringify({status: 'not_found'});
        if (request.validate_only) return JSON.stringify({status: 'validated', persistent_id: chosen.id, persistent_ids: [chosen.id]});
        music.play(chosen.track);
        return JSON.stringify({status: confirm(chosen.id) ? 'playing' : 'unavailable', persistent_id: chosen.id});
    }
    var resolved = request.tracks.map(function (track) { return find(track.ids, track); });
    if (resolved.some(function (track) { return !track; })) return JSON.stringify({status: 'incomplete_album'});
    var ids = resolved.map(function (track) { return track.id; });
    if (ids.some(function (id, index) { return ids.indexOf(id) !== index; })) return JSON.stringify({status: 'invalid_album'});
    if (request.validate_only) return JSON.stringify({status: 'validated', first_id: ids[0], track_count: ids.length, persistent_ids: ids});
    // Assemble the complete queue before starting Music. Appending to a playlist
    // after it starts need not update Music's already-created playback queue.
    var following = request.following_tracks || [];
    if (!Array.isArray(following) || following.some(function (item) { return !item || item.kind !== 'song' || !validIDs(item.ids); })) {
        return JSON.stringify({status: 'invalid_id'});
    }
    var continuation = [];
    for (var f = 0; f < following.length; f++) {
        var next = find(following[f].ids);
        if (!next || ids.indexOf(next.id) !== -1 || continuation.some(function (item) { return item.id === next.id; })) break;
        continuation.push(next);
    }
    var followingIDs = continuation.map(function (item) { return item.id; });
    var fullIDs = ids.concat(followingIDs);
    var owner = 'Managed by AM Track: ' + request.owner, playlist, playlistID;
    var previousShuffle = music.shuffleEnabled(), previousRepeat = music.songRepeat(), started = false, modesChanged = false;
    try {
        // A fresh, app-owned playlist keeps the previous queue intact if assembly fails.
        // Music requires object.make() at its default location; app.make() and collection.push() fail in JXA.
        playlist = music.UserPlaylist({name: 'AM Track · ' + request.album, description: owner});
        playlist.make();
        playlistID = playlist.persistentID();
        // Assemble the full album and its single recommended follow-up before
        // playback. Later recommendations are held locally by AM Track.
        var sourceTracks = resolved.concat(continuation);
        sourceTracks.forEach(function (track) { music.duplicate(track.track, {to: playlist}); });
        var queued = playlist.tracks.persistentID();
        var expectedSource = fullIDs;
        if (JSON.stringify(queued) !== JSON.stringify(expectedSource)) throw new Error('Album playlist order could not be confirmed.');
        if (request.validate_queue_only) return JSON.stringify({status: 'queue_validated', first_id: ids[0], track_count: ids.length});
        modesChanged = true;
        music.shuffleEnabled = false;
        music.songRepeat = 'off';
        music.play(playlist);
        if (!confirm(ids[0], playlistID)) throw new Error('Music did not start the first album track.');
        music.playerPosition = 0;
        if (music.shuffleEnabled() || music.songRepeat() !== 'off' || music.playerPosition() > 2) {
            throw new Error('Music did not confirm playback from the beginning in album order.');
        }
        started = true;
        // Never identify a managed playlist by its name, and never delete library tracks.
        if (request.previous_playlist_id && request.previous_playlist_id !== playlistID) {
            var old = music.playlists.whose({persistentID: request.previous_playlist_id});
            if (old.persistentID().length === 1 && old[0].description() === owner) {
                try { music.delete(old[0]); } catch (_) { /* An old managed playlist may remain if Music refuses cleanup. */ }
            }
        }
        return JSON.stringify({status: 'playing', persistent_id: ids[0], track_count: ids.length, from_start: true, playlist_id: playlistID, following_ids: followingIDs, album_ids: ids});
    } finally {
        if (!started) {
            if (modesChanged) { music.shuffleEnabled = previousShuffle;music.songRepeat = previousRepeat; }
            if (playlist) { try { music.delete(playlist); } catch (_) { /* Preserve the original failure. */ } }
        }
    }
}
