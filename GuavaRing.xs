#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include "const-c.inc"

/////////////////////////// guava-hash code ///////////////////////////////
int guava(long state, unsigned int buckets);

static const long
	K   = 2862933555777941757L;

static const double
	D   = 0x1.0p31;

int guava(long state, unsigned int buckets) {
	int candidate = 0;
	int next;
	while (1) {
		state = K * state + 1;
		next = (int) ( (double) (candidate + 1) / ( (double)( (int)( (long unsigned) state >> 33 ) + 1 ) / D ) );
		if ( ( next >= 0 ) && ( next < buckets )) {
			candidate = next;
		} else {
			return candidate;
		}
	}
}


/////////////////////// END guava-hash code ///////////////////////////////

#ifndef likely
#define likely(x)       __builtin_expect(!!(x), 1)
#define unlikely(x)     __builtin_expect(!!(x), 0)
#endif

typedef struct {
	I32   len;
	I32   cap;
	U16 * av;
} i_array;

typedef struct {
	SV * self;
	HV * stash;
	int  replica_count;
	i_array nodes;
	HV * pos;
} GuavaRing;

static I32 bisect(i_array * a, U16 k) {
	I32 hi = a->len - 1;
	if ( hi == -1 ) return 0;
	if ( k <= a->av[0] ) return 0;
	if ( k > a->av[hi] ) return hi+1;
	I32 lo = 0, mi = 0;
	while (lo + 1 < hi) {
		mi = lo + ( hi - lo ) / 2;
		if ( k > a->av[mi] ) {
			lo = mi;
		}
		else {
			hi = mi;
		}
	}
	return lo+1;
}

static void insort(i_array * a, U16 k) {
	if (unlikely(a->cap < a->len+1)) croak("Array overflow: %d", a->cap);
	I32 pos = bisect(a, k);
	memmove(&a->av[pos+1], &a->av[pos], sizeof(a->av[0]) * ( a->len - pos ) );
	a->av[pos] = k;
	a->len++;
}

#define svstrcmp(a,b) strcmp(SvPV_nolen(a),b)


MODULE = Hash::GuavaRing		PACKAGE = Hash::GuavaRing

void new(...)
	PPCODE:
		if (items < 1) croak("Usage: %s->new(...)",SvPV_nolen(ST(0)));
		GuavaRing * self = (GuavaRing *) safemalloc( sizeof(GuavaRing) );
		if (unlikely(!self)) croak("Failed to allocate memory");
		memset(self,0,sizeof(GuavaRing));
		self->stash = gv_stashpv(SvPV_nolen(ST(0)), TRUE);
		{
			SV *iv = newSViv(PTR2IV( self ));
			self->self = sv_bless(newRV_noinc (iv), self->stash);
			ST(0) = sv_2mortal(sv_bless (newRV_noinc(iv), self->stash));
		}
		int i,k,j;
		SV **key;
		AV *nodes = 0;
		self->replica_count = 100;
		for ( i=1; i < items; i=i+2) {
			if ( !svstrcmp(ST(i),"replica_count") ) {
				self->replica_count = SvUV(ST(i+1));
			}
			else
			if ( !svstrcmp(ST(i),"nodes") ) {
				if (SvROK(ST(i+1)) && SvTYPE(SvRV(ST(i+1))) == SVt_PVAV) {
					nodes = (AV *) SvRV( ST(i+1) );
				} else {
					croak("nodes must be arrayref, but got %s", SvPV_nolen(ST(i+1)));
				}
			}
			else {
				croak("Uknown option '%s'", SvPV_nolen(ST(i)));
			}
		}

		self->nodes.av = safemalloc( self->replica_count * (1+av_len(nodes)) * sizeof( self->nodes.av[0] ) );
		if (unlikely(!self->nodes.av)) croak("Failed to allocate memory");
		self->nodes.cap = self->replica_count * (1+av_len(nodes));

		self->pos = newHV();

		for ( i = 0; i <= av_len( nodes ); i++ ) {
			key = av_fetch( nodes, i, 0 );
			AV *node = (AV *) SvRV( *key );
			for ( k = 1; k <= self->replica_count; k++) {
				SV *hashkey = sv_2mortal(newSVpvf("('%s', '%s'):%d", SvPV_nolen( *av_fetch(node,0, 0) ), \
					SvPV_nolen( *av_fetch(node,1, 0) ), k));
				U16 kv = guava(hashkey,self->nodes.len);
				while (1) {
					if (unlikely(hv_exists(self->pos,(char *)&kv,sizeof(kv)))) {
						kv++;
					}
					else {
						hv_store(self->pos,(char *)&kv, sizeof(kv), SvREFCNT_inc( *key ), 0);
						break;
					}
				}
				insort( &self->nodes, kv );
				/*
				warn("node: %d : %s -> %d",i, SvPV_nolen(hashkey), kv);
				for (j=0;j<self->nodes.len;j++) {
					printf("%d, ",self->nodes.av[j]);
				}
				printf("\n");
				*/
			}
		}
		XSRETURN(1);

void DESTROY(SV *this)
	PPCODE:
		register GuavaRing *self = ( GuavaRing * ) SvUV( SvRV( ST(0) ) );
		if (self->nodes.cap > 0) {
			safefree(self->nodes.av);
			self->nodes.cap = 0;
		}
		if (self->pos) SvREFCNT_dec(self->pos);
		if (self->self && SvOK(self->self) && SvOK( SvRV(self->self) )) {
			SvREFCNT_inc(SvRV(self->self));
			SvREFCNT_dec(self->self);
		}
		safefree(self);
		XSRETURN_UNDEF;

void get (SV *this, SV * key)
	PPCODE:
		register GuavaRing *self = ( GuavaRing * ) SvUV( SvRV( ST(0) ) );
		U16 idx = guava( key, self->nodes.len );
		U16 pos = self->nodes.av[idx];
		SV **node = hv_fetch(self->pos, (char *)&pos, sizeof(pos), 0 );
		ST(0) = *node;
		//ST(0) = sv_2mortal(newRV_inc( (SV *) SvRV(*node) ));
		XSRETURN(1);
