#include <gtest/gtest.h>
#include "MoqiTextService/TouchKeyboard.h"
#include "TypeDuckRegistration.h"

TEST(TouchKeyboard, OnlyUnicodePagingPacketsAreCommands) {
  using Moqi::TouchKeyboard::IsPageKey;
  EXPECT_TRUE(IsPageKey(VK_PACKET, 0xf003));
  EXPECT_TRUE(IsPageKey(VK_PACKET, 0xf004));
  EXPECT_FALSE(IsPageKey(VK_NEXT, 0xf003));
  EXPECT_FALSE(IsPageKey(VK_PACKET, L'n'));
  EXPECT_FALSE(IsPageKey(VK_PACKET, 0x4f60));
}

TEST(TouchKeyboard, UnicodeJyutpingKeysKeepPhysicalKeyMeaning) {
  using Moqi::TouchKeyboard::EngineKeyCode;
  for (UINT c = L'a'; c <= L'z'; ++c)
    EXPECT_EQ(c - L'a' + L'A', EngineKeyCode(VK_PACKET, c));
  for (UINT c = L'0'; c <= L'9'; ++c)
    EXPECT_EQ(c, EngineKeyCode(VK_PACKET, c));
  EXPECT_EQ(VK_SPACE, EngineKeyCode(VK_PACKET, L' '));
  EXPECT_EQ(VK_RETURN, EngineKeyCode(VK_PACKET, L'\r'));
  EXPECT_EQ(VK_BACK, EngineKeyCode(VK_PACKET, L'\b'));
  EXPECT_EQ(VK_LEFT, EngineKeyCode(VK_LEFT, 0));
  EXPECT_EQ(VK_PACKET, EngineKeyCode(VK_PACKET, 0x4f60));
  EXPECT_EQ(VK_PACKET, EngineKeyCode(VK_PACKET, 0xf003));
}

TEST(RegistrationLocale, AcceptsOnlyTheTwoSupportedLocales) {
  using TypeDuckRegistration::NormalizeLocale;
  EXPECT_STREQ(L"zh-HK", NormalizeLocale(L"ZH-hk"));
  EXPECT_STREQ(L"zh-TW", NormalizeLocale(L"zh-TW"));
  for (const auto locale : {L"", L"zh-CN", L"en-US", L"zh-TW ", L"zh-Hant-HK"})
    EXPECT_EQ(nullptr, NormalizeLocale(locale));
}
