#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include "const-c.inc"

MODULE = Hash::GuavaRing		PACKAGE = Hash::GuavaRing		

INCLUDE: const-xs.inc
