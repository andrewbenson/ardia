#ifndef SOLARA_CORE_AC_SAFE_STORAGE_H_
#define SOLARA_CORE_AC_SAFE_STORAGE_H_

namespace base {
class CommandLine;
}

namespace solaracore {

void GuardSafeStorageKey(const base::CommandLine& command_line);

}

#endif
