// Standalone check of the cosmetic engine (no Chromium needed):
//   clang++ -std=c++20 -O2 -I$SRC chromium/adblock/cosmetic_selftest.cc \
//     $SRC/chrome/browser/agens_adblock/cosmetic_engine.cc -o /tmp/cosmetic_selftest
//   /tmp/cosmetic_selftest [list.txt ...]   # extra args: time + size on real lists
#include <cassert>
#include <chrono>
#include <fstream>
#include <iostream>
#include <sstream>

#include "chrome/browser/agens_adblock/cosmetic_engine.h"

using agens_adblock::CosmeticEngine;

static bool Has(const std::string& css, const char* sel) {
  return css.find(std::string(sel) + "{display:none!important}\n") !=
         std::string::npos;
}

int main(int argc, char** argv) {
  CosmeticEngine e;
  e.AddList(
      "! comment\n[Adblock Plus 2.0]\n"
      "##.ad-banner\n"
      "##.ad-banner\n"
      "##.shared\n"
      "example.com##.only-example\n"
      "a.com,b.com,~sub.a.com###box\n"
      "~news.org##.not-news\n"
      "example.com#@#.shared\n"
      "#@#.killed-everywhere\n"
      "##.killed-everywhere\n"
      "x.com##.bad:has-text(foo)\n"
      "x.com##.bad{color:red}\n"
      "google.*##.entity\n"
      "x.com#?#.procedural\n"
      "||ads.example^$third-party\n",
      agens_adblock::kStandard);
  e.AddList("##.cookie-gdpr\nshop.fr##.cookie-shop\n", agens_adblock::kCookie);
  e.Finish();

  std::string g = e.CssFor("foo.org", 1, true);
  assert(Has(g, ".ad-banner") && Has(g, ".shared") && Has(g, ".not-news"));
  assert(!Has(g, ".killed-everywhere") && !Has(g, ".bad:has-text(foo)"));
  assert(!Has(g, ".only-example") && !Has(g, ".cookie-gdpr"));
  assert(g.find(".ad-banner{") == g.rfind(".ad-banner{"));  // deduped
  std::string ex = e.CssFor("www.example.com", 1, true);
  assert(Has(ex, ".only-example") && !Has(ex, ".shared"));
  assert(!Has(e.CssFor("news.org", 1, true), ".not-news"));
  assert(Has(e.CssFor("a.com", 1, false), "#box"));
  assert(Has(e.CssFor("deep.b.com", 1, false), "#box"));
  assert(!Has(e.CssFor("sub.a.com", 1, false), "#box"));
  assert(!Has(e.CssFor("a.com", 1, false), ".ad-banner"));  // no generic
  assert(Has(e.CssFor("foo.org", 3, true), ".cookie-gdpr"));
  assert(Has(e.CssFor("shop.fr", 2, false), ".cookie-shop"));
  assert(e.CssFor("foo.org", 0, true).empty());
  std::cout << "ok\n";

  if (argc > 1) {
    CosmeticEngine big;
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 1; i < argc; ++i) {
      std::ifstream f(argv[i]);
      std::stringstream ss;
      ss << f.rdbuf();
      big.AddList(ss.str(), i == 1 ? agens_adblock::kStandard
                                   : agens_adblock::kStrong);
    }
    big.Finish();
    auto t1 = std::chrono::steady_clock::now();
    std::cout << "parse ms "
              << std::chrono::duration<double, std::milli>(t1 - t0).count()
              << " rules " << big.rule_count() << "\n";
    for (const char* h : {"www.nytimes.com", "www.uol.com.br", "example.org"}) {
      auto a = std::chrono::steady_clock::now();
      std::string css = big.CssFor(h, 7, true);
      auto b = std::chrono::steady_clock::now();
      std::cout << h << " css bytes " << css.size() << " build us "
                << std::chrono::duration<double, std::micro>(b - a).count()
                << "\n";
    }
  }
}
