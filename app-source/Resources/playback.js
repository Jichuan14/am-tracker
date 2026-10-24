// Lightweight queue/menu observation. Recording continues to use the complete sample reader.
var music = Application('com.apple.Music');
var result = {running: music.running()};
if (result.running) {
    result.state = music.playerState();
    if (result.state !== 'stopped') {
        var t = music.currentTrack;
        function read(fn, fallback) { try { return fn(); } catch (_) { return fallback; } }
        result.title = read(function () { return t.name(); }, '');
        result.artist = read(function () { return t.artist(); }, '');
        result.album = read(function () { return t.album(); }, '');
        result.album_artist = read(function () { return t.albumArtist(); }, '');
        result.track_class = read(function () { return t.class(); }, '');
        result.persistent_id = read(function () { return t.persistentID(); }, '');
        result.duration = read(function () { return t.duration(); }, 0);
        result.position = read(function () { return music.playerPosition(); }, 0);
    }
}
JSON.stringify(result);
