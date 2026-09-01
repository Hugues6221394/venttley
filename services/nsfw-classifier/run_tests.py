#!/usr/bin/env python3
"""Run test_decide.py without pytest.

The verdict logic decides whether somebody's post is deleted, so being able to
check it must not depend on a test runner happening to be installed on whatever
machine someone is sitting at. fastapi is stubbed for the same reason — app.py
imports it at module level and none of it is needed to test a pure function.

    ./run_tests.py
"""

import importlib.util
import sys
import types


def _stub_fastapi() -> None:
    try:
        import fastapi  # noqa: F401
        return
    except ImportError:
        pass

    module = types.ModuleType("fastapi")

    class _App:
        def __init__(self, **_kwargs):
            pass

        def get(self, *_a, **_k):
            return lambda fn: fn

        def post(self, *_a, **_k):
            return lambda fn: fn

    class HTTPException(Exception):
        def __init__(self, status_code=None, detail=None):
            super().__init__(detail)

    module.FastAPI = _App
    module.File = lambda *_a, **_k: None
    module.UploadFile = object
    module.HTTPException = HTTPException
    sys.modules["fastapi"] = module

    responses = types.ModuleType("fastapi.responses")
    responses.JSONResponse = lambda payload, **_k: payload
    sys.modules["fastapi.responses"] = responses


def main() -> int:
    _stub_fastapi()

    spec = importlib.util.spec_from_file_location("app", "app.py")
    app = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(app)
    sys.modules["app"] = app

    spec = importlib.util.spec_from_file_location("test_decide", "test_decide.py")
    tests = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tests)

    passed = failed = 0
    for name, cls in sorted(vars(tests).items()):
        if not (name.startswith("Test") and isinstance(cls, type)):
            continue
        instance = cls()
        for method in sorted(m for m in dir(instance) if m.startswith("test_")):
            try:
                getattr(instance, method)()
                passed += 1
                print("  PASS  %s.%s" % (name, method))
            except Exception as exc:  # noqa: BLE001 - report, do not raise
                failed += 1
                print("  FAIL  %s.%s -> %r" % (name, method, exc))

    print("\n%d passed, %d failed" % (passed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
