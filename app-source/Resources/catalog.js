// Read exact library identities and local catalog metadata. Never reveal, activate or play.
function catalogIDFromPackage(xml) {
    var master=xml.match(/<MasterPlaylist>([\s\S]*?)<\/MasterPlaylist>/);
    var url=master && master[1].match(/<NetworkURL>([^<]+)<\/NetworkURL>/);
    if (!url || !/^https:\/\/[^/]+\.(itunes|apple)\.com\//.test(url[1])) return null;
    var streams=xml.match(/<Streams>([\s\S]*?)<\/Streams>/);
    if (!streams) return null;
    var ids=[],pattern=/P[0-9]+_A([1-9][0-9]*)(?=[_.\/"'&<\-])/g,match;
    while ((match=pattern.exec(streams[1]))) if (ids.indexOf(match[1])<0) ids.push(match[1]);
    return ids.length===1 ? ids[0] : null;
}
function validCatalogID(value) { return typeof value==='string' && /^[1-9][0-9]{0,18}$/.test(value) && !/[^0-9]/.test(value); }
function run(argv) {
    ObjC.import('Foundation');ObjC.import('AVFoundation');
    var requests=JSON.parse(argv[0]||'[]'),music=Application('com.apple.Music');
    if (!Array.isArray(requests) || requests.length>2000) throw new Error('Invalid catalog request');
    if (!music.running()) return JSON.stringify({status:'unavailable',tracks:[]});
    var library=music.libraryPlaylists[0].tracks;
    var maximum=argv.length>1 ? Math.max(0,Math.min(2000,Number(argv[1]))) : 2000,resolved=0;
    function fromFile(track) {
        try {
            // The Apple-event file reference grants access to this exact media item.
            var path=track.location().toString();
            if (/\.movpkg\/?$/.test(path)) {
                var xml=$.NSString.stringWithContentsOfFileEncodingError($(path+'/boot.xml'),$.NSUTF8StringEncoding,null);
                return xml ? catalogIDFromPackage(ObjC.unwrap(xml)) : null;
            }
            var asset=$.AVURLAsset.URLAssetWithURLOptions($.NSURL.fileURLWithPath($(path)),null);
            var items=asset.metadataForFormat($.AVMetadataFormatiTunesMetadata);
            for (var j=0;j<items.count;j++) {
                var item=items.objectAtIndex(j);
                if (ObjC.unwrap(item.identifier)===ObjC.unwrap($.AVMetadataIdentifieriTunesMetadataSongID)) {
                    var value=ObjC.unwrap(item.stringValue);
                    return validCatalogID(value) ? value : null;
                }
            }
        } catch (_) {}
        return null;
    }
    var output=requests.map(function(request,index) {
        if (resolved>=maximum) return {index:index,status:'not_requested'};
        if (!request || !Array.isArray(request.ids) || !request.ids.length || !request.ids.every(function(id){return typeof id==='string' && /^[0-9A-F]{16}$/.test(id);})) return {index:index,status:'invalid_id'};
        for (var i=0;i<request.ids.length;i++) {
            var matches=library.whose({persistentID:request.ids[i]});
            if (matches.persistentID().length!==1) continue;
            var embedded=fromFile(matches[0]),known=validCatalogID(request.catalog_id) ? request.catalog_id : null;
            if (embedded && known && embedded!==known) return {index:index,status:'identity_conflict'};
            var catalog=embedded||known;
            if (catalog) resolved++;
            return {index:index,status:catalog?'resolved':'no_catalog_id',persistent_id:request.ids[i],catalog_id:catalog};
        }
        return {index:index,status:'not_found'};
    });
    return JSON.stringify({status:'resolved',tracks:output});
}
