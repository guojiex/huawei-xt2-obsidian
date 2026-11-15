/*
 * AppUpdateCheck.ets 鈥斺€?搴旂敤鍐呮娴嬫洿鏂帮紙v1.17锛屾柟鍚?A锛夈€? *
 * 鎺ュ彛涓€寰嬩互 docs/harmonyos/api_notes.md V 缁勪负鍑嗭紙V1 checkAppUpdate / V4 showUpdateDialog锛? * 鍧?@since 5.0.0(12) 鈮?24锛孲tage 涓撶敤锛屾棤鏉冮檺瑕佹眰锛夛細
 *  - 缁撹鍙彇 updateAvailable 鐨勩€屾湁 / 鏃犳柊鐗堟湰銆嶈涔夛紙V2锛夛紱涓嶈 versionName / versionCode
 *    锛圴3 鍏冩湇鍔′笓鐢ㄥ瓧娈碉紝涓€寰嬩笉璇伙紝涓嶆樉绀哄競鍦虹増鏈彿銆佷笉鍋氬鎴风鐗堟湰姣旇緝锛夈€? *  - 鏈夋柊鐗堟湰鏃惰皟绯荤粺鍗囩骇寮规 showUpdateDialog 鎺ョ寮曞锛圴4锛夛紝涓嶈嚜瀹氫箟寮规銆佷笉鎷煎競鍦鸿烦杞€? *  - 澶辫触鎸?V6 閿欒鐮佽嚦灏戝尯鍒嗗洓绫伙細1009400003 缃戠粶銆?009400004 涓嶅湪鍓嶅彴銆? *    1009400005 鏈悓鎰忓競鍦洪殣绉佸崗璁€?009400006 闄愭祦锛涘叾浣欏綊閫氱敤澶辫触锛岀爜鍊煎彧杩?hilog
 *    璇婃柇鏃ュ織锛屼笉寮瑰師濮嬬爜缁欑敤鎴枫€? *  - 妫€鏌ワ紙checkAppUpdate锛変笌寮规锛坰howUpdateDialog锛夌殑鎶涢敊鍒楄〃涓嶅悓锛圴6锛氬脊妗嗗垪琛ㄤ笉鍚? *    1009400003锛夛紝涓や釜 catch 鍒嗘敮鍒嗗紑鍐欙紝涓嶅叡鐢ㄤ竴濂楅敊璇槧灏勩€? *
 * 2026-11-15 鍐峰惎鍔ㄤ紭鍖栵紙XT2 trace锛夛細updateManager锛園kit.AppGalleryKit锛変粠鏈枃浠堕潤鎬佷緷璧? * 鎷嗗埌璁惧灞?AppUpdateCheckDevice锛坮unAppUpdateCheck / showSystemUpdateDialog 鍘熸牱鎼Щ锛夛紝
 * 鐢?SettingsView 鍔ㄦ€?import 鈥斺€?鐢ㄦ埛鐐广€屾鏌ユ洿鏂般€嶆椂鎵嶆媺璧凤紝鍚姩鍥句笉鍐嶅姞杞姐€? *
 * 鍐峰嵈锛圖-3 宸插畾锛夛細5 鍒嗛挓锛岃法浼氳瘽鎸佷箙鍖栦笂娆℃鏌ユ椂闂翠笌缁撴灉锛圥references锛夈€傚喎鍗村€兼槸搴旂敤鍐? * 宸ョ▼閫夋嫨锛屼笉鏄畼鏂规壙璇猴紙V5锛歝heckAppUpdate 瀹樻柟闄愭祦闃堝€兼湭璁拌浇锛屽喎鍗存湡鍐呯偣鎸変笉鑱旂綉锛? * 鐩存帴鏄剧ず涓婃缁撴灉锛夈€備粎鐢辩敤鎴蜂富鍔ㄧ偣鍑昏Е鍙戯紝鏃犲悗鍙拌疆璇€佷笉鍥犲惎鍔ㄥ彂璧凤紙D-2 / V5锛夈€? */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 鐣岄潰闃舵锛堝搴斿師鍨嬪叧浜庨〉 updateDemoStates 鐨?8 鎬?+ 绯荤粺寮规澶辫触鍏滃簳鎬侊級銆?*/
export type AppUpdateUiPhase = 'idle' | 'checking' | 'available' | 'latest' |
  'network' | 'background' | 'privacy' | 'limited' | 'generic' | 'dialog_failed';

/**
 * 搴旂敤鍐呭喎鍗存椂闀匡紙D-3锛? 鍒嗛挓锛夈€傚伐绋嬮€夋嫨鑰岄潪瀹樻柟鎵胯锛圴5锛夛紝椤诲湪鐪熸満瑙傚療銆? */
export const APP_UPDATE_COOLDOWN_MS: number = 5 * 60 * 1000;

const UPDATE_CHECK_TAG: string = 'AppUpdateCheck';

/** 鍐峰嵈涓偣鎸夋樉绀虹殑涓婃缁撴灉鏂囨鎵€闇€鏃堕挓锛圚H:MM锛夈€?*/
export function formatCheckClock(timestampMs: number): string {
  const date: Date = new Date(timestampMs);
  const hours: number = date.getHours();
  const minutes: number = date.getMinutes();
  const hoursText: string = hours < 10 ? '0' + hours.toString() : hours.toString();
  const minutesText: string = minutes < 10 ? '0' + minutes.toString() : minutes.toString();
  return hoursText + ':' + minutesText;
}

/** 鍐峰嵈鏄惁浠嶅湪鐢熸晥锛圖-3锛氳法浼氳瘽鎸佷箙鍖栫殑涓婃妫€鏌ユ椂闂?+ 5 鍒嗛挓绐楀彛锛夈€?*/
export function cooldownActive(lastCheckMs: number, nowMs: number): boolean {
  if (lastCheckMs <= 0) {
    return false;
  }
  return nowMs - lastCheckMs < APP_UPDATE_COOLDOWN_MS;
}

/**
 * V6 閿欒鐮?鈫?鍥涚被澶辫触 + 閫氱敤銆備粎鐢ㄤ簬 checkAppUpdate 鐨?catch锛? * showUpdateDialog 鐨勬姏閿欏垪琛ㄤ笉鍚?1009400003锛屽脊妗嗗垎鏀崟鐙鐞嗭紝涓嶅叡鐢ㄦ鏄犲皠銆? */
export function classifyCheckError(code: number): 'network' | 'background' | 'privacy' | 'limited' | 'generic' {
  if (code === 1009400003) {
    return 'network';
  }
  if (code === 1009400004) {
    return 'background';
  }
  if (code === 1009400005) {
    return 'privacy';
  }
  if (code === 1009400006) {
    return 'limited';
  }
  return 'generic';
}

/** 涓婃鑱旂綉妫€鏌ョ殑缁撴灉锛堟寔涔呭寲鍊硷紱available 鏃跺喎鍗存湡鍐呯偣鎸夌洿鎺ュ啀璋冪郴缁熷脊妗嗭紝涓嶅啀鑱旂綉妫€鏌ワ級銆?*/
export type AppUpdateLastOutcome = 'latest' | 'available';

/** 鍐峰嵈鎸佷箙鍖栵紙Preferences锛?app_update_check'锛岄敭 lastCheckMs / lastOutcome锛夈€?*/
export class AppUpdateCheckStore {
  private static readonly PREF_NAME: string = 'app_update_check';
  private static readonly KEY_LAST_CHECK_MS: string = 'lastCheckMs';
  private static readonly KEY_LAST_OUTCOME: string = 'lastOutcome';
  private readonly store: preferences.Preferences | null;
  private readonly available: boolean;

  constructor(context: common.UIAbilityContext) {
    let opened: preferences.Preferences | null = null;
    let ok: boolean = false;
    try {
      opened = preferences.getPreferencesSync(context, { name: AppUpdateCheckStore.PREF_NAME });
      ok = opened !== null;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, UPDATE_CHECK_TAG, 'open store failed: %{public}d', err.code);
    }
    this.store = opened;
    this.available = ok;
  }

  isAvailable(): boolean {
    return this.available && this.store !== null;
  }

  loadLastCheckMs(): number {
    if (this.store === null) {
      return 0;
    }
    try {
      return this.store.getSync(AppUpdateCheckStore.KEY_LAST_CHECK_MS, 0) as number;
    } catch (error) {
      return 0;
    }
  }

  loadLastOutcome(): AppUpdateLastOutcome {
    if (this.store === null) {
      return 'latest';
    }
    try {
      const raw: string = this.store.getSync(AppUpdateCheckStore.KEY_LAST_OUTCOME, 'latest') as string;
      return raw === 'available' ? 'available' : 'latest';
    } catch (error) {
      return 'latest';
    }
  }

  saveOutcome(lastCheckMs: number, outcome: AppUpdateLastOutcome): void {
    if (this.store === null) {
      return;
    }
    try {
      this.store.putSync(AppUpdateCheckStore.KEY_LAST_CHECK_MS, lastCheckMs);
      this.store.putSync(AppUpdateCheckStore.KEY_LAST_OUTCOME, outcome);
      this.store.flush();
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(0x0000, UPDATE_CHECK_TAG, 'save outcome failed: %{public}d', err.code);
    }
  }
}

/** 涓€娆℃鏌ュ姩浣滅殑缁撴灉锛氱晫闈㈤樁娈?+ 鍐峰嵈鏂囨鎵€闇€鐨勪笂娆℃鏌ユ椂閽熴€?*/
export interface AppUpdateCheckOutcome {
  phase: AppUpdateUiPhase;
  lastCheckClock: string;
}
