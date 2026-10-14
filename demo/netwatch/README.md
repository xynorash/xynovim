# netwatch (demo crate)

A tiny TCP port watcher used by the xynovim README, the demo recordings under
`docs/media/` and as a realistic target for manual testing: a library with a
trait, a CLI, unit and integration tests and features (`json`, `ssr`, `csr`).

```
cd demo/netwatch && cargo run -- 127.0.0.1 --ports 22,80,8000-8003
cargo test
```
