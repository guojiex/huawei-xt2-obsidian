#!/usr/bin/env python3
"""从应用配置生成原型与 ArkTS 配置；--check 验证生成内容一致。"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    config = json.loads((ROOT / 'app_config.json').read_text())
    email = config['feedbackEmail']
    if not isinstance(email, str) or not re.fullmatch(r'[A-Za-z0-9.!#$%&\'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', email):
        raise SystemExit('feedbackEmail 必须是有效邮箱，不得包含换行或邮件参数')
    ets_path = ROOT / 'entry/src/main/ets/model/AppConfig.ets'
    ets_updated = "// 由 app_config.json 生成；请勿手动修改。\nexport const FEEDBACK_EMAIL: string = " + \
        json.dumps(email, ensure_ascii=False) + ";\n"
    if args.check:
        if not ets_path.exists() or ets_path.read_text() != ets_updated:
            raise SystemExit('应用配置生成内容过期，请运行 python3 tools/build_app_config.py')
        print('App config and ArkTS output match; v2 preview settings use sync_settings_data.py')
    else:
        ets_path.write_text(ets_updated)

if __name__ == '__main__':
    main()
