"""Low-level in-memory tables. Only storage.repo should touch this."""

_TABLES = {}


def table(name):
    return _TABLES.setdefault(name, {})


def all_rows(name):
    return list(table(name).values())


def put_row(name, key, row):
    table(name)[key] = row


def get_row(name, key):
    return table(name).get(key)


def reset():
    _TABLES.clear()
