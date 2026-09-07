#pragma once

#include <Processors/ISource.h>
#include <Interpreters/AsynchronousInsertQueue.h>
#include <Interpreters/ProcessList.h>
#include <IO/Progress.h>

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
    Chunk generate() override
    {
        /// Interruptible by the query's own time limit and by KILL QUERY; empty under
        /// `timeout_overflow_mode = 'break'` when the limit passed, and then the source just ends.
        auto maybe_progress = AsynchronousInsertQueue::waitForResult(insert_future, timeout_ms, process_list_elem);
        if (!maybe_progress)
            return {};

        auto progress_result = *maybe_progress;

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
