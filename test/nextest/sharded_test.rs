//! Sharded across three Bazel shards, which the runner maps onto nextest's native
//! `--partition hash:i/m`. Every test must run in exactly one shard.

#[test] fn shard_a() {}
#[test] fn shard_b() {}
#[test] fn shard_c() {}
#[test] fn shard_d() {}
#[test] fn shard_e() {}
#[test] fn shard_f() {}
