# Observer commands record their last call in the reports directory. Tests
# that do not pass their own directory must not touch the developer's real
# one, so the default points into a directory owned by this run.
suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
reports_directory = Path.join(System.tmp_dir!(), "insider-lab-test-reports-" <> suffix)

System.put_env("INSIDER_LIVE_REPORTS_DIR", reports_directory)
System.at_exit(fn _status -> File.rm_rf(reports_directory) end)

ExUnit.start()
