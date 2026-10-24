#!/usr/bin/env python3
"""Authorization tests for ops-gateway.py. Run: python3 -I ops/gateway/test_ops_gateway.py"""
import importlib.util
import os
import unittest

spec = importlib.util.spec_from_file_location("gw", os.path.join(os.path.dirname(__file__), "ops-gateway.py"))
gw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gw)

BK = "/mnt/incus-backups"
BRADY = "brady@example.com"
GRANTS = {(BRADY, "can_create_instances", "project:mine"), (BRADY, "can_view", "project:mine"), (BRADY, "can_view", "project:ro")}


def check(user, rel, obj):
    return (user, rel, obj) in GRANTS


def start(action, params, admin=False):
    gw.authorize_start(check, BRADY, admin, action, params, BK)


class AuthorizeStart(unittest.TestCase):
    def test_operator_can_create_and_delete_in_own_project(self):
        start("create-instance", {"project": "mine"})
        start("delete-instance", {"project": "mine", "instance": "x"})
        start("delete-instance", {"items": [{"project": "mine", "instance": "x"}]})
        start("backup", {"project": "mine", "instance": "x"})

    def test_other_project_denied(self):
        for params in ({"project": "other"}, {"project": "ro"}, {"items": [{"project": "mine"}, {"project": "other"}]}):
            with self.assertRaises(gw.Denied):
                start("create-instance", params)
            with self.assertRaises(gw.Denied):
                start("delete-instance", params)

    def test_project_actions_are_admin_only(self):
        for action in ("create-project", "delete-project"):
            with self.assertRaises(gw.Denied):
                start(action, {"project": "mine", "name": "mine", "project_id": 9})
            start(action, {"project": "mine"}, admin=True)

    def test_missing_or_bad_project(self):
        for params in ({}, {"project": ""}, {"project": "../x"}, {"project": "a b"}, {"project": 5}, {"items": "x"}):
            with self.assertRaises(gw.Denied):
                start("create-instance", params)

    def test_unknown_action(self):
        with self.assertRaises(gw.Denied):
            start("shell", {"project": "mine"}, admin=True)
        with self.assertRaises(gw.Denied):
            start("create-instance", "mine")

    def test_restore_only_from_own_instance_backup(self):
        ok = f"{BK}/mine/web01/20261023.tar.gz"
        start("restore", {"project": "mine", "instance": "web01", "backup_file": ok})
        for bad in (
            f"{BK}/other/web01/a.tar.gz",
            f"{BK}/mine/db01/a.tar.gz",
            f"{BK}/mine/web01/../../other/web01/a.tar.gz",
            f"{BK}/minex/web01/a.tar.gz",
            "/etc/passwd",
            "",
        ):
            with self.assertRaises(gw.Denied, msg=bad):
                start("restore", {"project": "mine", "instance": "web01", "backup_file": bad})


class Visibility(unittest.TestCase):
    def test_visibility(self):
        self.assertTrue(gw.visible_to(check, BRADY, False, {"project": "mine"}))
        self.assertTrue(gw.visible_to(check, BRADY, False, {"project": "ro"}))
        self.assertFalse(gw.visible_to(check, BRADY, False, {"project": "other"}))
        self.assertFalse(gw.visible_to(check, BRADY, False, {"name": "newproj", "project_id": 9}))
        self.assertFalse(gw.visible_to(check, BRADY, False, {"items": [{"project": "mine"}, {"project": "other"}]}))
        self.assertTrue(gw.visible_to(check, BRADY, True, {"project": "other"}))


if __name__ == "__main__":
    unittest.main()
