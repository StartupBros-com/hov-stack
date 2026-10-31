"""Build an argv vector without invoking a shell."""


def build_command(project):
    return ('tool inspect --project ' + project).split()
