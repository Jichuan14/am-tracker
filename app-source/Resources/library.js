// Bulk read, preserving one last-played timestamp per library track.
var music = Application('com.apple.Music');
if (!music.running()) {
    JSON.stringify({running: false});
} else {
    var t = music.libraryPlaylists[0].tracks;
    var names = t.name(), artists = t.artist(), albums = t.album();
    var ids = t.persistentID(), counts = t.playedCount(), dates = t.playedDate();
    var genres = t.genre(), durations = t.duration();
    var albumArtists = t.albumArtist(), discs = t.discNumber(), discCounts = t.discCount();
    var numbers = t.trackNumber(), trackCounts = t.trackCount();
    var tracks = names.map(function (title, i) {
        var d = dates[i];
        return {persistent_id: ids[i], title: title, artist: artists[i], album: albums[i],
                genre: genres[i], duration: durations[i], album_artist: albumArtists[i],
                disc_number: discs[i], disc_count: discCounts[i], track_number: numbers[i], track_count: trackCounts[i],
                play_count: counts[i], last_played: d && !isNaN(d.getTime()) ? d.toISOString() : null};
    });
    JSON.stringify({running: true, tracks: tracks});
}
