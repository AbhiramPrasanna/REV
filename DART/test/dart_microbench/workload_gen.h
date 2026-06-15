#pragma once
//
// dart_microbench/workload_gen.h
//
// In-memory "working set" generator for DART, replacing the YCSB text-file
// pipeline (workload_download.py -> ycsb -> *_load/*_run -> YCSB::FileLoader).
//
// It produces the SAME record type that YCSB::Benchmark consumes
//   YCSB::FileLoader::records == vec<tup<operat, key, value, end_key>>   (spans)
// so it is a drop-in source: hand the iterators to the benchmark engine and
// every op flows into the registered PrheartTree lambdas exactly as a parsed
// YCSB file would. See ./integration.md for the (small) wiring.
//
// Distributions are reused from the DEX microbench generators that already sit
// in test/: ../zipf.h (mehcached_zipf_*) and ../uniform.h (UniformRandom).
//
// Header-only. Depends only on the DART include/ tree and the two generators.
//
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

#include "measure/measure.hpp"   // span, u8, vec, str, key::save_t, BufferBlock
#include "ycsb/ycsb.hpp"         // YCSB::operat, YCSB::FileLoader::{records,saving}

#include "../zipf.h"             // struct zipf_gen_state, mehcached_zipf_*
#include "../uniform.h"          // UniformRandom

namespace dart_bench {

using YCSB::operat;
using Records = YCSB::FileLoader::records;  // vec<tup<operat, span, span, span>>
using Saving  = YCSB::FileLoader::saving;   // tup<operat, save_t, save_t, save_t>

// --------------------------------------------------------------------------
// What working set to build. All sizes are absolute counts (not "millions").
// read+insert+update+scan+remove must sum to 100 (asserted).
// --------------------------------------------------------------------------
struct WorkloadSpec {
    uint64_t key_count  = 1'000'000;   // distinct keys bulk-loaded == the working set
    uint64_t op_count   = 1'000'000;   // measured run operations

    uint32_t read_pct   = 100;         // point lookup
    uint32_t insert_pct = 0;           // inserts FRESH keys (beyond the working set)
    uint32_t update_pct = 0;           // update existing key
    uint32_t scan_pct   = 0;           // range scan of ~scan_len keys
    uint32_t remove_pct = 0;           // delete existing key

    bool     uniform    = true;        // true = uniform; false = zipfian
    double   theta      = 0.99;        // zipf skew, ignored when uniform
    uint32_t value_len  = 16;          // payload bytes for insert/update
    uint32_t scan_len   = 100;         // approx keys returned per scan
    uint64_t seed       = 0xc70f6907ULL;
};

// --------------------------------------------------------------------------
// Generator. Owns one BufferBlock that backs every key/value/end_key span;
// records are built only AFTER all bytes are appended, so spans stay valid
// even though BufferBlock grows by push_back (same discipline as FileLoader).
// --------------------------------------------------------------------------
class WorkloadGenerator {
  public:
    explicit WorkloadGenerator(const WorkloadSpec& spec) : spec_(spec) { build(); }

    // Drop-in feeds for YCSB::Benchmark (see integration.md).
    Records& load_records() noexcept { return load_; }   // pure inserts of the working set
    Records& run_records()  noexcept { return run_; }    // the measured op mix

    uint64_t load_len() const noexcept { return load_.size(); }
    uint64_t run_len()  const noexcept { return run_.size(); }
    const WorkloadSpec& spec() const noexcept { return spec_; }

  private:
    // Bijection on 2^64 (odd multiplier is invertible): distinct i -> distinct
    // key, scattered across the key space just like CityHash does for DEX.
    static constexpr uint64_t kGolden = 0x9E3779B97F4A7C15ULL;
    static uint64_t scramble(uint64_t i) noexcept { return i * kGolden; }

    static constexpr key::save_t kNone{0, 0};

    void build() {
        assert(spec_.read_pct + spec_.insert_pct + spec_.update_pct +
                   spec_.scan_pct + spec_.remove_pct == 100 &&
               "op ratios must sum to 100");
        assert(spec_.key_count > 0);

        // ---- shared value blob (content is irrelevant to index cost) --------
        {
            str v(spec_.value_len, 'v');
            val_save_ = {buf_.size(), v.size()};
            buf_.add_strviw(v);
        }

        // ---- key table: scramble(0..key_count-1) as big-endian u64 ----------
        // add_u64 writes MSB-first, so byte-wise tree order == numeric order.
        key_save_.resize(spec_.key_count);
        for (uint64_t i = 0; i < spec_.key_count; ++i) {
            key_save_[i] = {buf_.size(), sizeof(uint64_t)};
            buf_.add_u64(scramble(i));
        }

        // ---- plan the run mix as savings (offsets), appending fresh bytes ---
        vec<Saving> run_save;
        run_save.reserve(spec_.op_count);

        // cumulative thresholds in [0,100)
        const uint32_t t_read   = spec_.read_pct;
        const uint32_t t_insert = t_read + spec_.insert_pct;
        const uint32_t t_update = t_insert + spec_.update_pct;
        const uint32_t t_scan   = t_update + spec_.scan_pct;
        // remainder -> remove

        // span width that makes a [k, k+width) range hold ~scan_len keys, given
        // key_count keys spread uniformly over 2^64.
        const uint64_t scan_width =
            (spec_.key_count ? (~0ULL / spec_.key_count) : 0) * spec_.scan_len;

        UniformRandom rng(spec_.seed);
        zipf_gen_state zs;
        if (!spec_.uniform)
            mehcached_zipf_init(&zs, spec_.key_count, spec_.theta,
                                spec_.seed & ((1UL << 48) - 1));

        uint64_t insert_cursor = spec_.key_count;  // fresh keys live past the WS

        auto pick_existing = [&]() -> uint64_t {
            uint64_t idx = spec_.uniform ? (rng.next_uint64() % spec_.key_count)
                                         : mehcached_zipf_next(&zs);
            return idx >= spec_.key_count ? spec_.key_count - 1 : idx;
        };

        for (uint64_t n = 0; n < spec_.op_count; ++n) {
            const uint32_t r = rng.next_uint32() % 100;

            if (r < t_read) {
                run_save.emplace_back(operat::read, key_save_[pick_existing()],
                                      kNone, kNone);
            } else if (r < t_insert) {
                key::save_t k{buf_.size(), sizeof(uint64_t)};
                buf_.add_u64(scramble(insert_cursor++));
                run_save.emplace_back(operat::insert, k, val_save_, kNone);
            } else if (r < t_update) {
                run_save.emplace_back(operat::update, key_save_[pick_existing()],
                                      val_save_, kNone);
            } else if (r < t_scan) {
                uint64_t idx = pick_existing();
                key::save_t end{buf_.size(), sizeof(uint64_t)};
                buf_.add_u64(scramble(idx) + scan_width);
                run_save.emplace_back(operat::scan, key_save_[idx], val_save_, end);
            } else {
                run_save.emplace_back(operat::remove, key_save_[pick_existing()],
                                      kNone, kNone);
            }
        }

        // ---- materialize records now that buf_ will not move again ----------
        // LOAD in SORTED key order (matches DEX bulk_load): sequential inserts
        // land on the tree's right edge, keeping the working path cache-resident
        // so most inserts are LOCAL instead of an RDMA round trip per key. This
        // changes ONLY the load order; key_save_ (and thus run_ indices) is left
        // in scramble(i) order, so the measured run mix is unaffected.
        vec<uint64_t> load_order(spec_.key_count);
        for (uint64_t i = 0; i < spec_.key_count; ++i) load_order[i] = i;
        std::sort(load_order.begin(), load_order.end(),
                  [](uint64_t a, uint64_t b) { return scramble(a) < scramble(b); });

        load_.reserve(spec_.key_count);
        for (uint64_t i = 0; i < spec_.key_count; ++i)
            load_.emplace_back(operat::insert,
                               buf_.get_span(key_save_[load_order[i]]),
                               buf_.get_span(val_save_), buf_.get_span(kNone));

        run_.reserve(run_save.size());
        for (auto& [op, k, v, e] : run_save)
            run_.emplace_back(op, buf_.get_span(k), buf_.get_span(v),
                              buf_.get_span(e));
    }

    WorkloadSpec spec_;
    key_value_buffer::BufferBlock buf_;
    vec<key::save_t> key_save_;
    key::save_t val_save_{0, 0};
    Records load_;
    Records run_;
};

}  // namespace dart_bench
