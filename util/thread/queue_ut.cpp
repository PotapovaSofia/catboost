#include "queue.h"

#include <library/unittest/registar.h>

#include <util/stream/output.h>
#include <util/random/fast.h>
#include <util/system/spinlock.h>

struct TMtpQueueTest {
    TSpinLock Lock;
    long R = -1;

    struct TTask: public IObjectInQueue {
        TMtpQueueTest* Test = nullptr;
        long Value = 0;

        TTask(TMtpQueueTest* test, int value)
            : Test(test)
            , Value(value)
        {
        }

        void Process(void*) override {
            TAutoPtr<TTask> This(this);

            TGuard<TSpinLock> guard(Test->Lock);
            Test->R ^= Value;
        }
    };

    struct TOwnedTask: public IObjectInQueue {
        bool& Processed;
        bool& Destructed;

        TOwnedTask(bool& processed, bool& destructed)
            : Processed(processed)
            , Destructed(destructed)
        {
        }

        ~TOwnedTask() override {
            Destructed = true;
        }

        void Process(void*) override {
            Processed = true;
        }
    };

    inline void TestAnyQueue(IMtpQueue* queue, size_t queueSize = 1000) {
        TReallyFastRng32 rand(17);
        const size_t cnt = 1000;

        R = 0;

        for (size_t i = 0; i < cnt; ++i) {
            R ^= (long)rand.GenRand();
        }

        queue->Start(10, queueSize);
        rand = TReallyFastRng32(17);

        for (size_t i = 0; i < cnt; ++i) {
            UNIT_ASSERT(queue->Add(new TTask(this, (long)rand.GenRand())));
        }

        queue->Stop();

        UNIT_ASSERT_EQUAL(0, R);
    }
};

class TFailAddQueue: public IMtpQueue {
public:
    bool Add(IObjectInQueue* /*obj*/) override Y_WARN_UNUSED_RESULT {
        return false;
    }

    void Start(size_t, size_t) override {
    }

    void Stop() noexcept override {
    }

    size_t Size() const noexcept override {
        return 0;
    }
};

Y_UNIT_TEST_SUITE(TMtpQueueTest) {
    Y_UNIT_TEST(TestTMtpQueue) {
        TMtpQueueTest t;
        TMtpQueue q;
        t.TestAnyQueue(&q);
    }

    Y_UNIT_TEST(TestTMtpQueueBlocking) {
        TMtpQueueTest t;
        TMtpQueue q(TMtpQueue::BlockingMode);
        t.TestAnyQueue(&q, 100);
    }

    // disabled by pg@ long time ago due to test flaps
    // Tried to enable: REVIEW:78772
    Y_UNIT_TEST(TestTAdaptiveMtpQueue) {
        if (false) {
            TMtpQueueTest t;
            TAdaptiveMtpQueue q;
            t.TestAnyQueue(&q);
        }
    }

    Y_UNIT_TEST(TestAddAndOwn) {
        TMtpQueue q;
        q.Start(2);
        bool processed = false;
        bool destructed = false;
        q.SafeAddAndOwn(new TMtpQueueTest::TOwnedTask(processed, destructed));
        q.Stop();

        UNIT_ASSERT_C(processed, "Not processed");
        UNIT_ASSERT_C(destructed, "Not destructed");
    }

    Y_UNIT_TEST(TestAddFunc) {
        TFailAddQueue queue;
        bool added = queue.AddFunc(
            []() {} // Lambda, I call him 'Lambda'!
        );
        UNIT_ASSERT_VALUES_EQUAL(added, false);
    }

    Y_UNIT_TEST(TestSafeAddFuncThrows) {
        TFailAddQueue queue;
        UNIT_CHECK_GENERATED_EXCEPTION(queue.SafeAddFunc([] {}), TMtpQueueException);
    }

    Y_UNIT_TEST(TestFunctionNotCopied) {
        struct TFailOnCopy {
            TFailOnCopy() {
            }

            TFailOnCopy(TFailOnCopy&&) {
            }

            TFailOnCopy(const TFailOnCopy&) {
                UNIT_FAIL("Don't copy std::function inside TMtpQueue");
            }
        };

        TMtpQueue queue(TMtpQueue::NonBlockingMode, TMtpQueue::CatchingMode);
        queue.Start(2);

        queue.SafeAddFunc([data = TFailOnCopy()]() {});

        queue.Stop();
    }
}
