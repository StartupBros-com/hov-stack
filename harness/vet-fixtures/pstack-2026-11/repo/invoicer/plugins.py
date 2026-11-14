"""Summary formats, picked by name with `summary_format = "..."` in invoicer.toml."""

from importlib import import_module

FORMATTERS = {
    "text": "invoicer.report:format_summary",
    "compact": "invoicer.report:format_summary_v1",
}


def load_formatter(name):
    module_name, _, attr = FORMATTERS[name].partition(":")
    return getattr(import_module(module_name), attr)
