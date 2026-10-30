#import <Cocoa/Cocoa.h>
#import "../SPHelpViewerController.h"
#import "SPPostgresHelpDataSource.h"

/// MySQL's help window, titled "PostgreSQL Help" ("PostgreSQL Help (<page title>)" while a page is shown).
__attribute__((visibility("default")))
@interface SPPostgresHelpViewerController : SPHelpViewerController
@end
