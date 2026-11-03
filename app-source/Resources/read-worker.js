// Read-only automation worker. Each request evaluates the existing reader in a fresh scope.
ObjC.import('Foundation');
function run(argv) {
    var input=$.NSFileHandle.fileHandleWithStandardInput;
    var output=$.NSFileHandle.fileHandleWithStandardOutput;
    var root=ObjC.unwrap($.NSString.stringWithString($.NSProcessInfo.processInfo.arguments.objectAtIndex(3)).stringByDeletingLastPathComponent);
    var sources={};
    ['playback','sample','library'].forEach(function(name) {
        sources[name]=ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(root+'/'+name+'.js',$.NSUTF8StringEncoding,null));
    });
    function execute(source) { return eval(source); }
    var line='';
    while (true) {
        var byte=input.readDataOfLength(1);
        if (Number(byte.length)===0) return;
        var c=ObjC.unwrap($.NSString.alloc.initWithDataEncoding(byte,$.NSUTF8StringEncoding));
        if (c!=='\n') { line+=c;continue; }
        var request, response;
        try {
            request=JSON.parse(line);
            if (!Object.prototype.hasOwnProperty.call(sources,request.script)) throw new Error('Unsupported Music reader');
            response={id:request.id,result:JSON.parse(execute(sources[request.script]))};
        } catch (error) { response={id:request ? request.id : null,error:String(error)}; }
        line='';
        output.writeData($.NSString.stringWithString(JSON.stringify(response)+'\n').dataUsingEncoding($.NSUTF8StringEncoding));
    }
}
