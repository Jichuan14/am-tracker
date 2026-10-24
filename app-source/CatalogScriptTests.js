ObjC.import('Foundation');
function run(argv) {
    var source=ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(argv[0],$.NSUTF8StringEncoding,null));
    var api=new Function(source+'\nreturn {parse:catalogIDFromPackage,valid:validCatalogID};')();
    function check(v,m){if(!v)throw new Error(m);}
    function xml(url){return '<HLSMoviePackage><Streams><Stream uri="'+url+'"/></Streams><MasterPlaylist><NetworkURL>'+url+'</NetworkURL></MasterPlaylist></HLSMoviePackage>';}
    check(api.parse('<HLSMoviePackage><Streams><Stream uri="https://audio-ssl.itunes.apple.com/P987654321_A1234567890_audio.mp4"/></Streams><MasterPlaylist><NetworkURL>https://aod.itunes.apple.com/master.m3u8</NetworkURL></MasterPlaylist></HLSMoviePackage>')==='1234567890','real packages keep the catalog ID in stream references, not necessarily the master URL');
    check(api.parse(xml('https://audio-ssl.itunes.apple.com/itunes-assets/HLSMusic221/P987654321_A1234567890_master.m3u8'))==='1234567890','downloaded package maps the exact asset catalog ID');
    check(api.parse(xml('https://audio-ssl.itunes.apple.com/P1_A1234567890_/P2_A1234567890_'))==='1234567890','repeated identical asset references are unambiguous');
    check(api.parse(xml('https://audio-ssl.itunes.apple.com/P1_A123_/P2_A456_'))===null,'conflicting catalog IDs are rejected');
    check(api.parse(xml('https://example.com/P1_A1234567890_'))===null,'unrecognized asset hosts are rejected');
    check(api.parse(xml('https://aod.itunes.apple.com/P987654321_A1234567890.movpkg'))==='1234567890','real package stream references can use a dot after the catalog ID');
    check(api.parse('<Name>P1_A1234567890_</Name>')===null,'song names and arbitrary filenames cannot supply an ID');
    check(api.parse(xml('https://audio-ssl.itunes.apple.com/no-id'))===null,'unmapped assets have no guessed fallback');
    check(!api.valid('ABCDEF0123456789')&&!api.valid('0')&&!api.valid('1234567890\n')&&api.valid('1234567890'),'catalog IDs are strictly decimal');
    return 'PASS: exact HLS catalog metadata, ambiguity/host checks, unsupported assets and ID namespace validation. No Music calls.';
}
