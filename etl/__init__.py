"""Orders pipeline stages: source -> bronze -> silver -> gold -> quality -> load.

Each stage lives in its own module. ``pipeline.py`` at the repo root wires them
together and is the entry point every environment runs.
"""
