#pragma once

#include <Processors/ISource.h>
#include <Interpreters/AsynchronousInsertQueue.h>
#include <Interpreters/ProcessList.h>
#include <IO/Progress.h>
#include <Common/Stopwatch.h>

namespace DB
{

namespace ErrorCodes
{
    extern const int TIMEOUT_EXCEEDED;
    extern const int LOGICAL_ERROR;
}

/// Source, that allow to wait until processing of
/// asynchronous insert for specified query_id will be finished.
class WaitForAsyncInsertSource final : public ISource
{
public:
    WaitForAsyncInsertSource(
        std::future<AsyncInsertProgress> insert_future_,
        size_t timeout_ms_,
        QueryStatusPtr process_list_elem_,
        ProgressCallback progress_callback_)
        : ISource(std::make_shared<const Block>())
        , insert_future(std::move(insert_future_))
        , timeout_ms(timeout_ms_)
        , process_list_elem(std::move(process_list_elem_))
        , progress_callback(std::move(progress_callback_))
    {
        chassert(insert_future.valid());
    }

    String getName() const override { return "WaitForAsyncInsert"; }

protected:
    /// Bounds the latency of noticing a kill or a time limit while waiting for the flush.
    static constexpr UInt64 max_wait_slice_ms = 100;

    Chunk generate() override
    {
        /// Wait in slices, so that the query's own time limit and KILL QUERY take effect while the
        /// flush is still running instead of when it finishes.
        Stopwatch watch;
        while (true)
        {
            const UInt64 elapsed_ms = watch.elapsedMilliseconds();
            const UInt64 slice_ms = std::min<UInt64>(timeout_ms > elapsed_ms ? timeout_ms - elapsed_ms : 0, max_wait_slice_ms);
            auto status = insert_future.wait_for(std::chrono::milliseconds(slice_ms));
            if (status == std::future_status::deferred)
                throw Exception(ErrorCodes::LOGICAL_ERROR, "Got future in deferred state");

            if (status == std::future_status::ready)
                break;

            if (watch.elapsedMilliseconds() >= timeout_ms)
                throw Exception(ErrorCodes::TIMEOUT_EXCEEDED, "Wait for async insert timeout ({} ms) exceeded", timeout_ms);

            /// Throws when the query was killed or its `max_execution_time` passed; returns false
            /// under `timeout_overflow_mode = 'break'`, in which case the query stops waiting.
            if (process_list_elem && !process_list_elem->checkTimeLimit())
                return {};
        }

        auto progress_result = insert_future.get();

        /// Report the written rows/bytes as progress so that query_log
        /// and HTTP X-ClickHouse-Summary reflect the actual insert stats.
        if (process_list_elem)
        {
            process_list_elem->updateProgressOut(Progress(WriteProgress(progress_result.rows, progress_result.bytes)));
            process_list_elem->updateProgressIn(Progress(DB::ReadProgress(progress_result.rows, progress_result.bytes)));
        }

        if (progress_callback)
        {
            Progress p;
            p.written_rows = progress_result.rows;
            p.written_bytes = progress_result.bytes;
            p.read_rows = progress_result.rows;
            p.read_bytes = progress_result.bytes;
            /// Do not set p.result_rows/result_bytes here: flushQueryProgress
            /// in executeQuery.cpp will derive them from progress_out.written_rows,
            /// so setting them here would cause double-counting in X-ClickHouse-Summary.
            progress_callback(p);
        }

        return Chunk();
    }

private:
    std::future<AsyncInsertProgress> insert_future;
    size_t timeout_ms;
    QueryStatusPtr process_list_elem;
    ProgressCallback progress_callback;
};

}
