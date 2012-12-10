#ifndef _XEDISK_H__
#define _XEDISK_H__

#ifdef __cplusplus
extern "C" {
#endif

#include <stdlib.h>

/** Initialize the library */
void XeDisk_Init(void);

/** Cleanup after using the library */
void XeDisk_Quit(void);

const char *XeDisk_GetLastError(void);

// Opaque pointer to the actual implementation
typedef struct XeDisk XeDisk;

typedef enum
{
	XeDiskOpenMode_ReadOnly, ///
	XeDiskOpenMode_ReadWrite, ///
}
XeDiskOpenMode;

XeDisk *XeDisk_OpenFile(const char *fileName, XeDiskOpenMode mode);
XeDisk *XeDisk_CreateFile(const char *fileName, const char *type,
	unsigned numSectors, unsigned bytesPerSector);
void XeDisk_Close(XeDisk *pDisk);
unsigned XeDisk_GetSectors(XeDisk* pDisk);
unsigned XeDisk_GetSectorSize(XeDisk* pDisk);
const char *XeDisk_GetType(XeDisk* pDisk);

#ifdef __cplusplus
} // extern "C"
#endif

#endif /* _XEDISK_H__ */
