import Foundation

// Only the visible For you surface supplies this context. Queue ranking remains pure.
enum RecommendationRefreshIntent { case revalidate,advance }
struct RecommendationExposure:Codable,Equatable {
    let id:String,albumID:String?,members:[String],isAlbum:Bool,at:Double
    init(_ item:Recommendation,at now:Date) {
        id=item.id;albumID=item.albumID;members=item.trackIDs;isAlbum=item.kind == .album;at=now.timeIntervalSince1970
    }
    func overlaps(_ item:Recommendation) -> Bool {
        if id==item.id { return true }
        if isAlbum { return item.kind == .song && members.contains(item.id) }
        return item.kind == .album && item.trackIDs.contains(id)
    }
}
struct RecommendationGeneration:Codable,Equatable {
    let number:Int,createdAt:Double
    var exposures:[RecommendationExposure]
}
struct RecommendationRotationState:Codable,Equatable {
    var version=1
    var generation=0
    var orderedIDs:[String]=[]
    var generations:[RecommendationGeneration]=[]
}
struct RecommendationExposurePriority:Comparable {
    let generation:Int,at:Double
    static func <(lhs:Self,rhs:Self) -> Bool {
        lhs.at==rhs.at ? lhs.generation<rhs.generation : lhs.at<rhs.at
    }
}
struct RecommendationRotationContext {
    let state:RecommendationRotationState,intent:RecommendationRefreshIntent,revision:String
    func priority(_ item:Recommendation,now:Date) -> RecommendationExposurePriority {
        // On advance these are the previous three generations, including the old current batch.
        // On passive refill include the current generation plus its three predecessors.
        let count=intent == .advance ? 3 : 4
        var result=RecommendationExposurePriority(generation:0,at:-.infinity)
        for generation in state.generations.suffix(count) {
            for exposure in generation.exposures where exposure.at<=now.timeIntervalSince1970 && now.timeIntervalSince1970-exposure.at<7*86400 && exposure.overlaps(item) {
                result=max(result,RecommendationExposurePriority(generation:generation.number,at:exposure.at))
            }
        }
        return result
    }
    var retainedIDs:[String] { intent == .revalidate ? state.orderedIDs : [] }
}
struct RecommendationRotationResult {
    let items:[Recommendation],state:RecommendationRotationState,revision:String
}

extension RecommendationSnapshot {
    func forYouResult(limit:Int=10) -> RecommendationRotationResult {
        precondition(rotation != nil)
        let context=rotation!,items=scored(limit:limit)
        var state=context.state
        if state.generation==0 || context.intent == .advance {
            state.generation += 1
            state.generations.append(RecommendationGeneration(number:state.generation,createdAt:now.timeIntervalSince1970,exposures:[]))
        }
        let index=state.generations.count-1
        let retained=Set(context.retainedIDs)
        for item in items where !retained.contains(item.id) {
            let exposure=RecommendationExposure(item,at:now)
            if let existing=state.generations[index].exposures.firstIndex(where:{$0.id==item.id}) {
                // A removed entry shown again is a new exposure, even in the same generation.
                state.generations[index].exposures[existing]=exposure
            } else { state.generations[index].exposures.append(exposure) }
        }
        state.orderedIDs=items.map{$0.id}
        // Retain at most four generations and seven days of deduplicated identities.
        // Expired current entries can stay visible; pruning never renews their exposure.
        state.generations=Array(state.generations.suffix(4)).map { generation in
            var value=generation
            value.exposures.removeAll{now.timeIntervalSince1970-$0.at>=7*86400}
            return value
        }
        return RecommendationRotationResult(items:items,state:state,revision:context.revision)
    }
}

extension Archive {
    static let recommendationRotationKey="for_you_rotation_v1"
    func forYouSnapshot(now:Date=Date(),intent:RecommendationRefreshIntent = .revalidate) throws -> RecommendationSnapshot {
        let revision=try value(Self.recommendationRotationKey)
        let state=revision.isEmpty ? RecommendationRotationState() : try JSONDecoder().decode(RecommendationRotationState.self,from:Data(revision.utf8))
        guard state.version==1,state.generation>=0,state.generations.count<=4,
              Set(state.orderedIDs).count==state.orderedIDs.count,
              (state.generation==0 ? state.generations.isEmpty && state.orderedIDs.isEmpty : state.generations.last?.number==state.generation),
              state.generations.allSatisfy({$0.number>0 && $0.createdAt.isFinite && Set($0.exposures.map{$0.id}).count==$0.exposures.count && $0.exposures.allSatisfy{$0.at.isFinite}}),
              zip(state.generations,state.generations.dropFirst()).allSatisfy({$0.number<$1.number}) else {
            throw AppError(message:"The saved For you rotation is invalid.")
        }
        var snapshot=try recommendationSnapshot(now:now)
        snapshot.rotation=RecommendationRotationContext(state:state,intent:intent,revision:revision)
        return snapshot
    }
    func commitForYouResult(_ result:RecommendationRotationResult,at now:Date) throws {
        try transaction {
            guard try value(Self.recommendationRotationKey)==result.revision else {
                throw AppError(message:"For you changed while recommendations were being prepared. Refresh again.")
            }
            let old=result.revision.isEmpty ? nil : try JSONDecoder().decode(RecommendationRotationState.self,from:Data(result.revision.utf8))
            guard old != result.state else { return }
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let encoded=String(decoding:try encoder.encode(result.state),as:UTF8.self)
            try meta(Self.recommendationRotationKey,encoded)
            // Revalidation without a changed list creates neither exposure nor an audit batch.
            if old?.generation != result.state.generation || old?.orderedIDs != result.state.orderedIDs {
                try logRecommendations(result.items,at:now)
            }
        }
    }
}
