import Foundation

// Bounded local diagnostics. Times use the monotonic clock and contain no song names.
final class QueueLatencyTrace {
    private let lock=NSLock()
    private var records:[[String:Any]]=[]
    private var dirty=false
    private var timer:DispatchSourceTimer?
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds)/1_000_000 }
    init(folder:URL) {
        let url=folder.appendingPathComponent("queue-latency.json")
        let timer=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"org.amtrack.app.queue-diagnostics",qos:.utility))
        timer.schedule(deadline:.now()+1,repeating:1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.dirty else { self.lock.unlock();return }
            let values=self.records;self.dirty=false;self.lock.unlock()
            if let data=try? JSONSerialization.data(withJSONObject:values,options:[.sortedKeys]) { try? data.write(to:url,options:.atomic) }
        }
        self.timer=timer;timer.resume()
    }
    deinit { timer?.cancel() }
    func record(_ phase:String,epoch:Int,request:Int=0,since:Double?=nil,cache:Int?=nil) {
        let now=Self.now()
        var row:[String:Any]=["phase":phase,"epoch":epoch,"request":request,"uptime_ms":now]
        if let since { row["duration_ms"]=max(0,now-since) }
        if let cache { row["cache_count"]=cache }
        lock.lock();defer{lock.unlock()}
        records.append(row);if records.count>256 { records.removeFirst(records.count-256) };dirty=true
    }
    var snapshot:[[String:Any]] { lock.lock();defer{lock.unlock()};return records }
}
