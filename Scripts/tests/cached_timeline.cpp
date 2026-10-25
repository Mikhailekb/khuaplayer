#include "SPCachedTimeline.hpp"
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>
using namespace spcachetime;
static int checks = 0;
static void check(bool ok, const char *message) {
    if (!ok) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
    ++checks;
}
int main() {
    check(metadataDuration(0,12000000)==12000000, "fast MP4 stream duration remains usable before format duration discovery");
    check(metadataDuration(-1,12000000)==12000000, "unknown format metadata uses known stream metadata without a bitrate estimate");
    check(metadataDuration(11000000,12000000)==11000000, "known format duration retains playback priority");
    check(metadataDuration(0,0)==0 && metadataDuration(-1,-1)==0, "unknown source duration stays unknown");
    auto spans = indexSpans({{0,0}, {100,10000000}, {1000,20000000}}, 2000, 30000000);
    auto times = covered(spans, normalizeBytes({{0,100}}, 2000), 30000000);
    check(times.size()==1 && times[0].lower==0 && times[0].upper==10000000, "VBR coverage follows real index timestamps rather than byte fraction");
    check(covered(spans, normalizeBytes({{0,99}},2000),30000000).empty(), "partial indexed interval is not interpolated");
    check(covered(spans, normalizeBytes({{0,49},{50,100}},2000),30000000).empty(), "one-byte missing hole prevents a whole-interval claim");
    times=covered(spans,normalizeBytes({{0,50},{50,100}},2000),30000000);
    check(times.size()==1 && times[0].upper==10000000, "adjacent complete byte ranges may cover the same interval");
    times=covered(spans,normalizeBytes({{100,1000}},2000),30000000);
    check(times.size()==1 && times[0].lower==10000000 && times[0].upper==20000000, "unrelated cached position maps to its own media time");
    times=covered(spans,normalizeBytes({{1000,2000}},2000),30000000);
    check(times.size()==1 && times[0].lower==20000000 && times[0].upper==30000000, "only fully resident static tail maps to declared duration");
    check(indexSpans({},2000,30000000).empty(), "duration alone cannot invent an unindexed timeline");
    check(indexSpans({{-1,0},{0,-1},{2001,100}},2000,30000000).empty(), "invalid index points are rejected");
    auto resident=normalizeBytes({{-10,20},{20,30},{40,50},{80,400},{90,95},{7,7}},100);
    check(resident.size()==3 && resident[0].lower==0 && resident[0].upper==30 && resident[2].upper==100, "resident intervals are clipped, sorted and merged without closing holes");
    check(!covers(resident,30,40) && covers(resident,80,100), "coverage checks use exclusive upper bounds");
    check(!covers(resident,-1,1) && !covers(resident,1,1), "invalid byte extents fail closed");
    times=normalizeTimes({{300,400},{0,100},{100,200},{50,180}},1000);
    check(times.size()==2 && times[0].lower==0 && times[0].upper==200 && times[1].lower==300, "out-of-PTS-order observed packets preserve real timestamp gaps");
    auto both=intersect({{0,5},{10,20}},{{2,8},{12,14}});
    check(both.size()==2 && both[0].lower==2 && both[0].upper==5 && both[1].lower==12 && both[1].upper==14, "selected audio and video coverage intersect instead of falsely unioning");
    check(intersect({{0,20}},{}).empty(), "unknown selected audio cannot produce confirmed A/V coverage");
    check(covered({{0,10,0,5},{20,30,10,15}},normalizeBytes({{0,30}},30),20).size()==2, "timestamp discontinuities remain separate despite contiguous cached bytes");
    check(covered({{100,600,0,1000}},normalizeBytes({{100,110}},1000),1000).empty(), "a repacked small packet cannot be inferred cached from its decompressed byte size");
    check(covered({{100,600,0,1000}},normalizeBytes({{100,600}},1000),1000).size()==1, "a complete conservative raw block can cover its observed timestamp");
    const int64_t max=std::numeric_limits<int64_t>::max();
    resident=normalizeBytes({{max-20,max}},max);
    check(covers(resident,max-20,max) && !covers(resident,max-21,max), "large byte offsets do not wrap through floating-point conversion");
    std::mt19937 random(271828);
    for (int iteration=0;iteration<20000;++iteration) {
        std::vector<ByteRange> raw;
        bool oracle[256]={};
        for (int j=0;j<8;++j) {
            int a=(int)(random()%320)-32,b=(int)(random()%320)-32;
            raw.push_back({a,b});
            for(int k=std::max(0,a);k<std::min(256,b);++k)oracle[k]=true;
        }
        auto normalized=normalizeBytes(raw,256);
        int a=random()%256,b=a+1+random()%(256-a);
        bool expected=true;for(int k=a;k<b;++k)expected=expected&&oracle[k];
        check(covers(normalized,a,b)==expected,"independent per-byte oracle agrees with exact union coverage");
    }
    std::cout << "Cached timeline checks passed (" << checks << " assertions).\n";
}
