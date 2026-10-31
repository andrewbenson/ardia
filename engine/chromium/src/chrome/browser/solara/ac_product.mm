// Copyright 2026 Solara. Apache-2.0.

#include "chrome/browser/solara/ac_product.h"

#import <Foundation/Foundation.h>

#include "base/apple/bundle_locations.h"
#include "base/files/file_path.h"
#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"

namespace solara {

const std::string& ProductName() {
  static const base::NoDestructor<std::string> name([] {
    NSString* product = [base::apple::OuterBundle()
        objectForInfoDictionaryKey:@"CFBundleName"];
    if ([product isKindOfClass:[NSString class]] && product.length) {
      return base::SysNSStringToUTF8(product);
    }
    return base::apple::OuterBundlePath().BaseName().RemoveExtension().value();
  }());
  return *name;
}

const std::u16string& ProductName16() {
  static const base::NoDestructor<std::u16string> name(
      base::UTF8ToUTF16(ProductName()));
  return *name;
}

}
