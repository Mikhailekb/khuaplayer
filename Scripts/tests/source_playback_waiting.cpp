#include "SPSourcePlaybackWaitingPolicy.hpp"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {
int checks = 0;
constexpr int64_t delay = 750000;

void expect(bool condition, const std::string& description) {
    ++checks;
    if (!condition) {
        std::cerr << "Source playback waiting check failed: " << description << std::endl;
        std::exit(1);
    }
}

spplaywait::Input input(int64_t nowUs = 0, uint64_t openGeneration = 1,
                       int64_t seekGeneration = 1) {
    spplaywait::Input value{};
    value.nowUs = nowUs;
    value.openGeneration = openGeneration;
    value.seekGeneration = seekGeneration;
    value.sessionActive = true;
    value.sourceEligible = true;
    value.playing = true;
    return value;
}

void healthyPrefetchChecks() {
    spplaywait::Policy policy;
    auto value = input();
    value.rawWaiting = true;
    auto result = policy.update(value);
    expect(!result.waiting && !result.blocking && !result.changed,
           "raw network prefetch does not imply blocked playback");
    value.nowUs = 10 * delay;
    result = policy.update(value);
    expect(!result.waiting && !result.blocking && !result.changed,
           "long healthy prefetch never reveals waiting");
    expect(!policy.waiting(), "healthy prefetch leaves the stored visible state clear");
    value.playing = false;
    value.nowUs += 10 * delay;
    result = policy.update(value);
    expect(!result.waiting && !result.blocking,
           "paused prefetch without a pending seek is not blocked playback");
    value.rawWaiting = false;
    value.rebufferHold = true;
    value.nowUs += 10 * delay;
    result = policy.update(value);
    expect(!result.waiting && !result.blocking,
           "a paused non-seek hold does not reveal source waiting");
}

void holdBoundaryChecks() {
    spplaywait::Policy policy;
    auto value = input();
    value.rebufferHold = true;
    auto result = policy.update(value);
    expect(result.blocking && !result.waiting && !result.changed,
           "a real hold blocks immediately without flashing a waiting notice");
    value.nowUs = delay - 1;
    result = policy.update(value);
    expect(result.blocking && !result.waiting && !result.changed,
           "waiting remains hidden one microsecond before the threshold");
    value.nowUs = delay;
    result = policy.update(value);
    expect(result.blocking && result.waiting && result.changed,
           "waiting becomes visible at 750000 microseconds, including a zero-clock start");
    expect(policy.waiting(), "visible waiting is retained in the policy");
    value.nowUs += delay;
    result = policy.update(value);
    expect(result.blocking && result.waiting && !result.changed,
           "an unchanged long hold does not repeatedly notify the UI");
    value.rebufferHold = false;
    value.rawWaiting = true;
    ++value.nowUs;
    result = policy.update(value);
    expect(!result.blocking && !result.waiting && result.changed,
           "recovering playback clears waiting immediately even while prefetch continues");
    ++value.nowUs;
    result = policy.update(value);
    expect(!result.changed, "an already-cleared state does not send another edge");
}

void shortHoldChecks() {
    spplaywait::Policy policy;
    auto value = input(100);
    value.rebufferHold = true;
    policy.update(value);
    value.nowUs = 100 + delay - 1;
    value.rebufferHold = false;
    auto result = policy.update(value);
    expect(!result.waiting && !result.blocking && !result.changed,
           "a short hold that recovers before the deadline never flashes a notice");
    value.nowUs += 1;
    value.rebufferHold = true;
    result = policy.update(value);
    expect(result.blocking && !result.waiting && !result.changed,
           "a second hold starts a fresh debounce interval");
    value.nowUs += delay - 1;
    expect(!policy.update(value).waiting, "two separate short holds do not accumulate elapsed time");
    ++value.nowUs;
    expect(policy.update(value).waiting, "the second hold can independently reach its threshold");
}

void pausedSeekChecks() {
    for (bool frameOnly : {false, true}) {
        spplaywait::Policy policy;
        auto value = input();
        value.playing = false;
        value.seekPending = !frameOnly;
        value.seekFramePending = frameOnly;
        value.rawWaiting = true;
        auto result = policy.update(value);
        expect(result.blocking && !result.waiting,
               "a paused seek with source IO pending is a real blocking operation");
        value.nowUs = delay;
        result = policy.update(value);
        expect(result.blocking && result.waiting && result.changed,
               "both pending-seek and pending-frame paths reveal a long paused seek");
        value.rawWaiting = false;
        ++value.nowUs;
        result = policy.update(value);
        expect(!result.blocking && !result.waiting && result.changed,
               "finishing source IO clears a paused seek notice even before seek flags settle");
        value.nowUs += 2 * delay;
        result = policy.update(value);
        expect(!result.blocking && !result.waiting,
               "pending frame bookkeeping alone does not imply a source download failure");
    }
}

void audioStarvationChecks() {
    spplaywait::Policy policy;
    auto value = input();
    value.audioStarved = true;
    value.rawWaiting = true;
    auto result = policy.update(value);
    expect(result.blocking && !result.waiting && !result.changed,
           "drained audio blocked on source IO starts the same hidden debounce interval");
    value.nowUs = delay - 1;
    expect(!policy.update(value).waiting, "drained audio does not reveal a notice before 750 milliseconds");
    ++value.nowUs;
    result = policy.update(value);
    expect(result.blocking && result.waiting && result.changed,
           "a sustained drained-audio source wait becomes visible at the threshold");
    value.audioStarved = false;
    ++value.nowUs;
    result = policy.update(value);
    expect(!result.blocking && !result.waiting && result.changed,
           "refilling audio immediately clears waiting even while source prefetch continues");
    value.nowUs += 2 * delay;
    result = policy.update(value);
    expect(!result.blocking && !result.waiting && !result.changed,
           "buffered audio with long background prefetch never shows a download notice");

    value.audioStarved = true;
    value.rawWaiting = false;
    ++value.nowUs;
    policy.update(value);
    value.nowUs += 2 * delay;
    result = policy.update(value);
    expect(!result.blocking && !result.waiting,
           "audio starvation without active source IO is not reported as source waiting");

    value.rawWaiting = true;
    value.playing = false;
    ++value.nowUs;
    policy.update(value);
    value.nowUs += 2 * delay;
    result = policy.update(value);
    expect(!result.blocking && !result.waiting,
           "an ordinary pause suppresses drained-audio source waiting");

    value.playing = true;
    value.sourceEligible = false;
    ++value.nowUs;
    policy.update(value);
    value.nowUs += 2 * delay;
    result = policy.update(value);
    expect(!result.blocking && !result.waiting,
           "an ineligible source cannot reveal a drained-audio network notice");

    value.sourceEligible = true;
    ++value.nowUs;
    policy.update(value);
    value.nowUs += delay;
    expect(policy.update(value).waiting, "eligible drained audio can reveal a later independent wait");
    value.rawWaiting = false;
    ++value.nowUs;
    result = policy.update(value);
    expect(!result.blocking && !result.waiting && result.changed,
           "source IO recovery clears an audio wait even before the starvation flag resets");
}

void eligibilityAndResetChecks() {
    for (bool closeSession : {false, true}) {
        spplaywait::Policy policy;
        auto value = input();
        value.rebufferHold = true;
        policy.update(value);
        value.nowUs = delay;
        expect(policy.update(value).waiting, "create a visible waiting state before recovery");
        if (closeSession) value.sessionActive = false;
        else value.sourceEligible = false;
        ++value.nowUs;
        const auto result = policy.update(value);
        expect(!result.waiting && !result.blocking && result.changed,
               "closing the session or changing to an ineligible source clears immediately");
    }

    spplaywait::Policy policy;
    auto value = input();
    value.rebufferHold = true;
    policy.update(value);
    value.nowUs = delay;
    policy.update(value);
    expect(policy.reset(), "reset reports that a visible waiting notice needs clearing");
    expect(!policy.waiting(), "reset removes the visible waiting state");
    expect(!policy.reset(), "resetting twice does not report a duplicate visible edge");
    value.nowUs = 0;
    auto result = policy.update(value);
    expect(result.blocking && !result.waiting,
           "the same generation can establish a fresh interval after an explicit reset");
    value.nowUs = delay;
    expect(policy.update(value).waiting, "a reset policy can reveal a later independent hold");
}

void generationChecks() {
    spplaywait::Policy policy;
    auto value = input(0, 10, 7);
    value.rebufferHold = true;
    policy.update(value);
    value.nowUs = delay;
    expect(policy.update(value).waiting, "create a visible hold in the old media generation");
    value.openGeneration = 11;
    value.seekGeneration = 1;
    ++value.nowUs;
    auto result = policy.update(value);
    expect(result.blocking && !result.waiting && result.changed,
           "a new source resets the deadline and accepts its lower seek generation");
    auto stale = value;
    stale.openGeneration = 10;
    stale.seekGeneration = 99;
    stale.rebufferHold = false;
    stale.nowUs += 10 * delay;
    result = policy.update(stale);
    expect(!result.blocking && !result.waiting && !result.changed,
           "an obsolete source cannot clear or reveal the new source's waiting state");
    value.nowUs += delay;
    result = policy.update(value);
    expect(result.waiting && result.changed, "the new source uses its own original interval");

    value.seekGeneration = 2;
    ++value.nowUs;
    result = policy.update(value);
    expect(result.blocking && !result.waiting && result.changed,
           "a newer seek resets an already-visible waiting interval");
    stale = value;
    stale.seekGeneration = 1;
    stale.rebufferHold = false;
    stale.nowUs += 10 * delay;
    result = policy.update(stale);
    expect(!result.blocking && !result.waiting && !result.changed,
           "a stale seek cannot mutate the newer seek's state or clock");
    value.nowUs += delay;
    result = policy.update(value);
    expect(result.waiting && result.changed, "a newer seek can later reveal its independent long wait");
    result = policy.update(stale);
    expect(!result.blocking && result.waiting && !result.changed,
           "late stale recovery cannot dismiss a currently visible new-seek wait");
}

void rollbackChecks() {
    spplaywait::Policy policy;
    auto value = input(1000000);
    value.rebufferHold = true;
    policy.update(value);
    value.nowUs += delay - 1;
    expect(!policy.update(value).waiting, "a partial pre-rollback interval remains hidden");
    value.nowUs = 200000;
    auto result = policy.update(value);
    expect(result.blocking && !result.waiting && !result.changed,
           "a backwards clock starts a fresh hidden interval without unsigned underflow");
    value.nowUs += delay - 1;
    expect(!policy.update(value).waiting, "pre-rollback elapsed time is not reused");
    ++value.nowUs;
    expect(policy.update(value).waiting, "the restarted clock interval uses the full delay");

    spplaywait::Policy partialRollback;
    value = input(1000000);
    value.rebufferHold = true;
    partialRollback.update(value);
    value.nowUs = 1600000;
    partialRollback.update(value);
    value.nowUs = 1200000;
    expect(!partialRollback.update(value).waiting,
           "a rollback can remain above the interval's original start");
    value.nowUs = 1750000;
    expect(!partialRollback.update(value).waiting,
           "a rollback above the original start does not inherit the old deadline");
    value.nowUs = 1950000;
    expect(partialRollback.update(value).waiting,
           "a partial rollback eventually reaches its restarted deadline");
    value.nowUs = 1900000;
    result = partialRollback.update(value);
    expect(result.blocking && !result.waiting && result.changed,
           "rolling back a visible interval hides it until a fresh delay elapses");
}

void waitReasonChecks() {
    using spplaywait::WaitReason;
    expect(spplaywait::waitReason(false, false) == WaitReason::none,
           "healthy playback has no waiting explanation");
    expect(spplaywait::waitReason(false, true) == WaitReason::none,
           "background source IO cannot manufacture a visible download notice");
    expect(spplaywait::waitReason(true, true) == WaitReason::sourceIO,
           "a visible hold with pending source IO explains that it is waiting for data");
    expect(spplaywait::waitReason(true, false) == WaitReason::pipelineHold,
           "a visible hold without source IO never blames downloading");

    spplaywait::Policy policy;
    auto value = input();
    value.rebufferHold = true;
    policy.update(value);
    value.nowUs = delay;
    auto result = policy.update(value);
    expect(result.waiting && result.blocking && !value.rawWaiting,
           "the existing remote pipeline hold can be visible without a pending read");
    expect(spplaywait::waitReason(result.waiting, value.rawWaiting) == WaitReason::pipelineHold,
           "an exhausted media queue is explained as playback preparation");

    value.rawWaiting = true;
    ++value.nowUs;
    result = policy.update(value);
    expect(result.waiting && !result.changed,
           "source IO may begin without another visible-waiting edge");
    expect(spplaywait::waitReason(result.waiting, value.rawWaiting) == WaitReason::sourceIO,
           "the explanation follows the current source IO fact while the hold remains visible");

    value.rawWaiting = false;
    ++value.nowUs;
    result = policy.update(value);
    expect(result.waiting && !result.changed,
           "completing source IO need not complete an existing pipeline hold");
    expect(spplaywait::waitReason(result.waiting, value.rawWaiting) == WaitReason::pipelineHold,
           "completing source IO removes the download explanation immediately");

    value.rebufferHold = false;
    ++value.nowUs;
    result = policy.update(value);
    expect(!result.waiting && spplaywait::waitReason(result.waiting, true) == WaitReason::none,
           "recovered playback clears its reason even when background IO continues");
    policy.reset();
    expect(spplaywait::waitReason(policy.waiting(), true) == WaitReason::none,
           "source reset cannot retain the preceding source's explanation");
}
}

int main() {
    healthyPrefetchChecks();
    holdBoundaryChecks();
    shortHoldChecks();
    pausedSeekChecks();
    audioStarvationChecks();
    eligibilityAndResetChecks();
    generationChecks();
    rollbackChecks();
    waitReasonChecks();
    std::cout << "Source playback waiting checks passed (" << checks << " assertions)." << std::endl;
}
