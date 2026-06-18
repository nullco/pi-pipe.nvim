import { test, describe } from "node:test";
import * as assert from "node:assert/strict";
import { isUnderOrSame, parsePidFromSocket } from "./helpers.ts";

describe("isUnderOrSame", () => {
  test("same path returns true", () => {
    assert.equal(isUnderOrSame("/a/b", "/a/b"), true);
  });

  test("child under parent returns true", () => {
    assert.equal(isUnderOrSame("/a/b/c", "/a"), true);
    assert.equal(isUnderOrSame("/a/b/c", "/a/b"), true);
  });

  test("parent under child (reverse direction) returns false", () => {
    assert.equal(isUnderOrSame("/a", "/a/b"), false);
  });

  test("unrelated paths return false", () => {
    assert.equal(isUnderOrSame("/a/b", "/x"), false);
    assert.equal(isUnderOrSame("/a/b", "/a-foo"), false); // prefix-but-not-boundary
  });

  test("trailing slash is normalized", () => {
    assert.equal(isUnderOrSame("/a/b/", "/a"), true);
    assert.equal(isUnderOrSame("/a/b", "/a/"), true);
  });

  test("exact string equal still works with trailing slash on both", () => {
    assert.equal(isUnderOrSame("/a/b/", "/a/b/"), true);
  });
});

describe("parsePidFromSocket", () => {
  test("bad format returns null", () => {
    assert.equal(parsePidFromSocket("not-a-socket"), null);
    assert.equal(parsePidFromSocket("pipe-abc.sock"), null);
    assert.equal(parsePidFromSocket("foo-12345.sock"), null);
  });

  test("valid format with live pid returns the pid", () => {
    const pid = process.pid;
    assert.equal(parsePidFromSocket(`pipe-${pid}.sock`), pid);
  });

  test("valid format with dead pid returns null", () => {
    // PID 1 is always alive on Linux; use a very large pid that is
    // effectively guaranteed not to exist.
    assert.equal(parsePidFromSocket("pipe-999999999.sock"), null);
  });
});
