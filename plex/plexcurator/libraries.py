"""Select Plex movie libraries from their locations and configured folder roots."""

import os

from . import zones


def configured_folders(cfg):
    return [
        os.path.normpath(path)
        for path in [
            cfg["folders"]["managed"],
            *(u["path"] for u in cfg["folders"]["unmanaged"]),
        ]
        if path
    ]


def _overlaps(path, folder):
    path, folder = os.path.normpath(path), os.path.normpath(folder)
    try:
        return os.path.commonpath((path, folder)) in (path, folder)
    except ValueError:
        return False


def section_overlaps_folder(cfg, section, folder):
    for location in section.get("Location", []):
        path = location.get("path") if isinstance(location, dict) else None
        if isinstance(path, str) and path:
            mapped = zones.map_path(cfg["plex"]["path_map"], path)
            if _overlaps(mapped, folder):
                return True
    return False


def selected_movie_sections(cfg, plex):
    sections = plex.movie_sections()
    selection = cfg["plex"]["libraries"]
    if selection == "all":
        return sections
    if selection == "configured":
        folders = configured_folders(cfg)
        return [
            section
            for section in sections
            if any(section_overlaps_folder(cfg, section, folder) for folder in folders)
        ]
    if (
        isinstance(selection, list)
        and selection
        and all(isinstance(title, str) and title.strip() for title in selection)
    ):
        requested = set(selection)
        available = {section["title"] for section in sections}
        missing = sorted(requested - available)
        if missing:
            raise ValueError(
                "configured Plex movie library title(s) not found: "
                + ", ".join(repr(title) for title in missing)
            )
        return [section for section in sections if section["title"] in requested]
    raise ValueError(
        "[plex] libraries must be 'configured', 'all', or a non-empty list of library titles"
    )
