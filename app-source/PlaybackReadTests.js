// Run the shipped lightweight reader against fakes only. No Apple events.
ObjC.import('Foundation');
function run(argv) {
    var source=ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(argv[0],$.NSUTF8StringEncoding,null));
    function check(value,message) { if (!value) throw new Error(message); }
    function scenario(state,closed,missing) {
        var calls=[];
        function value(name,result) { return function(){calls.push(name);if(missing && name==='album') throw new Error('Unavailable');return result;}; }
        var fake={running:value('running',!closed),playerState:value('state',state),playerPosition:value('position',3),currentTrack:{
            name:value('title','Song'),artist:value('artist','Artist'),album:value('album','Album'),albumArtist:value('album_artist','Album artist'),
            class:value('track_class','urlTrack'),persistentID:value('persistent_id','0000000000000001'),duration:value('duration',180),
            discNumber:function(){throw new Error('Queue read must not request disc metadata');},trackNumber:function(){throw new Error('Queue read must not request ordering metadata');}
        }};
        function Application(id) { check(id==='com.apple.Music','exact application');return fake; }
        var result=JSON.parse(new Function('Application',source.replace('JSON.stringify(result);','return JSON.stringify(result);'))(Application));
        return {result:result,calls:calls};
    }
    var playing=scenario('playing',false,false);
    check(playing.result.track_class==='urlTrack' && playing.result.duration===180 && playing.result.persistent_id==='0000000000000001','complete guarded identity inputs survive lightweight reading');
    check(playing.result.album_artist==='Album artist' && playing.result.position===3,'current song UI values remain available');
    check(scenario('paused',false,false).result.state==='paused','paused state remains distinct');
    check(scenario('playing',false,true).result.album==='','missing metadata remains empty for conservative matching');
    check(scenario('stopped',false,false).calls.length===2,'stopped Music needs no current track reads');
    check(scenario('playing',true,false).calls.length===1,'closed Music is never launched or queried');
    return 'PASS: lightweight playback fields, metadata fallback, paused/stopped/closed reads. Fake Music only.';
}
