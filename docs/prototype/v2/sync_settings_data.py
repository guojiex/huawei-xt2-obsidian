"""Generate the standalone design's settings snapshot from repository sources."""
import argparse
import json
from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[3]
TARGET = Path(__file__).with_name('index.html')
BEGIN = '/* SETTINGS_DATA_BEGIN */'
END = '/* SETTINGS_DATA_END */'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    helpers = runpy.run_path(str(ROOT / 'tools/generators/build_changelog.py'))
    entries = helpers['validate'](json.loads((ROOT / 'changelog.json').read_text()))
    # 用户可见条目（非 internal 且非 pending），与 App 内 ChangelogData.ets 同源同规则。
    visible = helpers['user_visible'](entries)
    entries = [{'version': entry['version'], 'date': entry['date'], 'title': entry['title'], 'changes': entry['changes']} for entry in visible]
    version, build = helpers['package_version']()
    config = json.loads((ROOT / 'app_config.json').read_text())
    data = dict(version=version, build=build, entries=entries,
                recent=entries[:3], feedbackEmail=config['feedbackEmail'],
                developerName=config['developerName'])
    block = BEGIN + '\nconst settingsData = ' + helpers['quoted'](data) + ';\n' + END
    text = TARGET.read_text()
    start = text.index(BEGIN)
    stop = text.index(END, start) + len(END)
    updated = text[:start] + block + text[stop:]
    if args.check:
        if updated != text:
            raise SystemExit('Settings snapshot is stale; run sync_settings_data.py')
    else:
        TARGET.write_text(updated)


if __name__ == '__main__':
    main()
