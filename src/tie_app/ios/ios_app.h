/* iOS integration: game folders in the app's Documents directory and the
 * on-screen flight controls. */
#ifndef TIE_APP_IOS_IOS_APP_H
#define TIE_APP_IOS_IOS_APP_H

#include <stdbool.h>
#include <stddef.h>

typedef struct TieLaunchOptions TieLaunchOptions;

/* Uses TIE95 and TIE98 installations found directly inside Documents when the
 * launch options name none. */
void TieIos_FindInstallations(TieLaunchOptions* launch);

/* The app container moves when iOS updates or reinstalls the app; re-roots a
 * saved path inside an old container's Documents onto the current one. */
void TieIos_RebaseDocumentsPath(char* path, size_t capacity);

/* After Aeron_Init: hides the screen keyboard and adds the touch overlay. */
void TieIos_Init(void);
/* Once per host frame, before the runtime tick. */
void TieIos_Frame(void);
void TieIos_Shutdown(void);

#endif
