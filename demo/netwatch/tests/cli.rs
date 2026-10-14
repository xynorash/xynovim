use assert_cmd::Command;
use predicates::prelude::*;

#[test]
fn reports_each_port() {
    Command::cargo_bin("netwatch")
        .unwrap()
        .args(["127.0.0.1", "--ports", "1,2", "--timeout", "100"])
        .assert()
        .success()
        .stdout(predicate::str::contains("127.0.0.1:1 closed").and(predicate::str::contains("127.0.0.1:2 closed")));
}

#[test]
fn bad_port_list_exits_2() {
    Command::cargo_bin("netwatch")
        .unwrap()
        .args(["--ports", "nope"])
        .assert()
        .code(2)
        .stderr(predicate::str::contains("bad port"));
}
