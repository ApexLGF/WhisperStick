#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "../i18n_catalog.generated.h"

int main() {
    assert(i18nGetLocale() == UI_LOCALE_EN);
    assert(strcmp(i18nText(UI_STR_BASIC_CONNECTED), "Connected") == 0);
    assert(strcmp(i18nText(UI_STR_HOME_NO_SESSIONS_READY), "No sessions · Voice ready") == 0);

    assert(i18nSetLocale(UI_LOCALE_ZH_HANS));
    assert(strcmp(i18nText(UI_STR_BASIC_CONNECTED), "已连接") == 0);
    assert(strcmp(i18nText(UI_STR_OTA_CONTROLS_LOCKED), "升级期间按键暂不可用。") == 0);
    assert(strcmp(i18nText(UI_STR_ACTION_CODEX_B), "B 下一个/新建/临时会话") == 0);

    assert(i18nSetLocale(UI_LOCALE_ZH_HANT));
    assert(strcmp(i18nText(UI_STR_BASIC_CONNECTED), "已連線") == 0);
    assert(strcmp(i18nText(UI_STR_RECOGNITION_WORKING), "正在辨識") == 0);

    assert(!i18nSetLocale(UI_LOCALE_COUNT));
    assert(i18nGetLocale() == UI_LOCALE_ZH_HANT);
    assert(strcmp(i18nTextFor(UI_STR_BASIC_CONNECTED, static_cast<UiLocale>(99)), "Connected") == 0);
    assert(strcmp(i18nText(static_cast<UiStringId>(UI_STR_COUNT)), "") == 0);

    char formatted[48];
    snprintf(formatted, sizeof(formatted), i18nText(UI_STR_RECORDING_INPUT_LEVEL), -24);
    assert(strcmp(formatted, "輸入音量 -24 dBFS") == 0);

    puts("i18n catalog: PASS");
    return 0;
}
