"""Known-good starting state for no-defect and continuation fixtures only."""


def build_command(project):
    return ['tool', 'inspect', '--project', project]
