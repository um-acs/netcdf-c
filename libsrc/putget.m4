dnl This is m4 source.
dnl Process using m4 to produce 'C' language file.
dnl
undefine(`begin')dnl
undefine(`index')dnl
undefine(`len')dnl
dnl
dnl If you see this line, you can ignore the next one.
/* Do not edit this file. It is produced from the corresponding .m4 source */
dnl
/*
 *	Copyright 1996, University Corporation for Atmospheric Research
 *      See netcdf/COPYRIGHT file for copying and redistribution conditions.
 */
/* $Id: putget.m4,v 2.79 2010/05/29 22:25:01 russ Exp $ */

#include "config.h"
#include <string.h>
#include <stdlib.h>
#include <assert.h>

#include "netcdf.h"
#include "nc3internal.h"
#include "ncx.h"
#include "fbits.h"
#include "onstack.h"
#ifdef LOCKNUMREC
#  include <mpp/shmem.h>	/* for SGI/Cray SHMEM routines */
#  ifdef LN_TEST
#    include <stdio.h>
#  endif
#endif
#include "nc3dispatch.h"


#undef MIN  /* system may define MIN somewhere and complain */
#define MIN(mm,nn) (((mm) < (nn)) ? (mm) : (nn))

static int
readNCv(const NC3_INFO* ncp, const NC_var* varp, const size_t* start,
        const size_t nelems, void* value, const nc_type memtype);
static int
writeNCv(NC3_INFO* ncp, const NC_var* varp, const size_t* start,
         const size_t nelems, const void* value, const nc_type memtype);


/* #define ODEBUG 1 */

#if ODEBUG
#include <stdio.h>
/*
 * Print the values of an array of size_t
 */
void
arrayp(const char *label, size_t count, const size_t *array)
{
	(void) fprintf(stderr, "%s", label);
	(void) fputc('\t',stderr);	
	for(; count > 0; count--, array++)
		(void) fprintf(stderr," %lu", (unsigned long)*array);
	(void) fputc('\n',stderr);	
}
#endif /* ODEBUG */


/* Begin fill */
/*
 * This is tunable parameter.
 * It essentially controls the tradeoff between the number of times
 * memcpy() gets called to copy the external data to fill 
 * a large buffer vs the number of times its called to
 * prepare the external data.
 */
#if	_SX
/* NEC SX specific optimization */
#define	NFILL	2048
#else
#define	NFILL	16
#endif


dnl
dnl NCFILL(Type, Xtype, XSize, Fill)
dnl
define(`NCFILL',dnl
`dnl
static int
NC_fill_$2(
	void **xpp,
	size_t nelems)	/* how many */
{
	$1 fillp[NFILL * sizeof(double)/$3];

	assert(nelems <= sizeof(fillp)/sizeof(fillp[0]));

	{
		$1 *vp = fillp;	/* lower bound of area to be filled */
		const $1 *const end = vp + nelems;
		while(vp < end)
		{
			*vp++ = $4;
		}
	}
	return ncx_putn_$2_$1(xpp, nelems, fillp);
}
')dnl

/*
 * Next 6 type specific functions
 * Fill a some memory with the default special value.
 * Formerly
NC_arrayfill()
 */
NCFILL(schar, schar, X_SIZEOF_CHAR, NC_FILL_BYTE)
NCFILL(char, char, X_SIZEOF_CHAR, NC_FILL_CHAR)
NCFILL(short, short, X_SIZEOF_SHORT, NC_FILL_SHORT)

#if (SIZEOF_INT >= X_SIZEOF_INT)
NCFILL(int, int, X_SIZEOF_INT, NC_FILL_INT)
#elif SIZEOF_LONG == X_SIZEOF_INT
NCFILL(long, int, X_SIZEOF_INT, NC_FILL_INT)
#else
#error "NC_fill_int implementation"
#endif

NCFILL(float, float, X_SIZEOF_FLOAT, NC_FILL_FLOAT)
NCFILL(double, double, X_SIZEOF_DOUBLE, NC_FILL_DOUBLE)




/* 
 * Fill the external space for variable 'varp' values at 'recno' with
 * the appropriate value. If 'varp' is not a record variable, fill the
 * whole thing.  For the special case when 'varp' is the only record
 * variable and it is of type byte, char, or short, varsize should be
 * ncp->recsize, otherwise it should be varp->len.
 * Formerly
xdr_NC_fill()
 */
int
fill_NC_var(NC3_INFO* ncp, const NC_var *varp, size_t varsize, size_t recno)
{
	char xfillp[NFILL * X_SIZEOF_DOUBLE];
	const size_t step = varp->xsz;
	const size_t nelems = sizeof(xfillp)/step;
	const size_t xsz = varp->xsz * nelems;
	NC_attr **attrpp = NULL;
	off_t offset;
	size_t remaining = varsize;

	void *xp;
	int status = NC_NOERR;

	/*
	 * Set up fill value
	 */
	attrpp = NC_findattr(&varp->attrs, _FillValue);
	if( attrpp != NULL )
	{
		/* User defined fill value */
		if( (*attrpp)->type != varp->type || (*attrpp)->nelems != 1 )
		{
			return NC_EBADTYPE;
		}
		else
		{
			/* Use the user defined value */
			char *cp = xfillp;
			const char *const end = &xfillp[sizeof(xfillp)];

			assert(step <= (*attrpp)->xsz);

			for( /*NADA*/; cp < end; cp += step)
			{
				(void) memcpy(cp, (*attrpp)->xvalue, step);
			}
		}
	}
	else
	{
		/* use the default */
		
		assert(xsz % X_ALIGN == 0);
		assert(xsz <= sizeof(xfillp));
	
		xp = xfillp;
	
		switch(varp->type){
		case NC_BYTE :
			status = NC_fill_schar(&xp, nelems);
			break;
		case NC_CHAR :
			status = NC_fill_char(&xp, nelems);
			break;
		case NC_SHORT :
			status = NC_fill_short(&xp, nelems);
			break;
		case NC_INT :
			status = NC_fill_int(&xp, nelems);
			break;
		case NC_FLOAT :
			status = NC_fill_float(&xp, nelems);
			break;
		case NC_DOUBLE : 
			status = NC_fill_double(&xp, nelems);
			break;
		default :
			assert("fill_NC_var invalid type" == 0);
			status = NC_EBADTYPE;
			break;
		}
		if(status != NC_NOERR)
			return status;
	
		assert(xp == xfillp + xsz);
	}

	/*
	 * copyout:
	 * xfillp now contains 'nelems' elements of the fill value
	 * in external representation.
	 */

	/*
	 * Copy it out.
	 */

	offset = varp->begin;
	if(IS_RECVAR(varp))
	{
		offset += (off_t)ncp->recsize * recno;
	}

	assert(remaining > 0);
	for(;;)
	{
		const size_t chunksz = MIN(remaining, ncp->chunk);
		size_t ii;

		status = ncio_get(ncp->nciop, offset, chunksz,
				 RGN_WRITE, &xp);	
		if(status != NC_NOERR)
		{
			return status;
		}

		/*
		 * fill the chunksz buffer in units  of xsz
		 */
		for(ii = 0; ii < chunksz/xsz; ii++)
		{
			(void) memcpy(xp, xfillp, xsz);
			xp = (char *)xp + xsz;
		}
		/*
		 * Deal with any remainder
		 */
		{
			const size_t rem = chunksz % xsz;
			if(rem != 0)
			{
				(void) memcpy(xp, xfillp, rem);
				/* xp = (char *)xp + xsz; */
			}

		}

		status = ncio_rel(ncp->nciop, offset, RGN_MODIFIED);

		if(status != NC_NOERR)
		{
			break;
		}

		remaining -= chunksz;
		if(remaining == 0)
			break;	/* normal loop exit */
		offset += chunksz;

	}

	return status;
}
/* End fill */


/*
 * Add a record containing the fill values.
 */
static int
NCfillrecord(NC3_INFO* ncp, const NC_var *const *varpp, size_t recno)
{
	size_t ii = 0;
	for(; ii < ncp->vars.nelems; ii++, varpp++)
	{
		if( !IS_RECVAR(*varpp) )
		{
			continue;	/* skip non-record variables */
		}
		{
		const int status = fill_NC_var(ncp, *varpp, (*varpp)->len, recno);
		if(status != NC_NOERR)
			return status;
		}
	}
	return NC_NOERR;
}


/*
 * Add a record containing the fill values in the special case when
 * there is exactly one record variable, where we don't require each
 * record to be four-byte aligned (no record padding).
 */
static int
NCfillspecialrecord(NC3_INFO* ncp, const NC_var *varp, size_t recno)
{
    int status;
    assert(IS_RECVAR(varp));
    status = fill_NC_var(ncp, varp, ncp->recsize, recno);
    if(status != NC_NOERR)
	return status;
    return NC_NOERR;
}


/*
 * It is advantageous to
 * #define TOUCH_LAST
 * when using memory mapped io.
 */
#if TOUCH_LAST
/*
 * Grow the file to a size which can contain recno
 */
static int
NCtouchlast(NC3_INFO* ncp, const NC_var *const *varpp, size_t recno)
{
	int status = NC_NOERR;
	const NC_var *varp = NULL;
	
	{
	size_t ii = 0;
	for(; ii < ncp->vars.nelems; ii++, varpp++)
	{
		if( !IS_RECVAR(*varpp) )
		{
			continue;	/* skip non-record variables */
		}
		varp = *varpp;
	}
	}
	assert(varp != NULL);
	assert( IS_RECVAR(varp) );
	{
		const off_t offset = varp->begin
				+ (off_t)(recno-1) * (off_t)ncp->recsize
				+ (off_t)(varp->len - varp->xsz);
		void *xp;


		status = ncio_get(ncp->nciop, offset, varp->xsz,
				 RGN_WRITE, &xp);	
		if(status != NC_NOERR)
			return status;
		(void)memset(xp, 0, varp->xsz);
		status = ncio_rel(ncp->nciop, offset, RGN_MODIFIED);
	}
	return status;
}
#endif /* TOUCH_LAST */


/*
 * Ensure that the netcdf file has 'numrecs' records,
 * add records and fill as necessary.
 */
static int
NCvnrecs(NC3_INFO* ncp, size_t numrecs)
{
	int status = NC_NOERR;
#ifdef LOCKNUMREC
	ushmem_t myticket = 0, nowserving = 0;
	ushmem_t numpe = (ushmem_t) _num_pes();

	/* get ticket and wait */
	myticket = shmem_short_finc((shmem_t *) ncp->lock + LOCKNUMREC_LOCK,
		ncp->lock[LOCKNUMREC_BASEPE]);
#ifdef LN_TEST
		fprintf(stderr,"%d of %d : ticket = %hu\n",
			_my_pe(), _num_pes(), myticket);
#endif
	do {
		shmem_short_get((shmem_t *) &nowserving,
			(shmem_t *) ncp->lock + LOCKNUMREC_SERVING, 1,
			ncp->lock[LOCKNUMREC_BASEPE]);
#ifdef LN_TEST
		fprintf(stderr,"%d of %d : serving = %hu\n",
			_my_pe(), _num_pes(), nowserving);
#endif
		/* work-around for non-unique tickets */
		if (nowserving > myticket && nowserving < myticket + numpe ) {
			/* get a new ticket ... you've been bypassed */ 
			/* and handle the unlikely wrap-around effect */
			myticket = shmem_short_finc(
				(shmem_t *) ncp->lock + LOCKNUMREC_LOCK,
				ncp->lock[LOCKNUMREC_BASEPE]);
#ifdef LN_TEST
				fprintf(stderr,"%d of %d : new ticket = %hu\n",
					_my_pe(), _num_pes(), myticket);
#endif
		}
	} while(nowserving != myticket);
	/* now our turn to check & update value */
#endif

	if(numrecs > NC_get_numrecs(ncp))
	{


#if TOUCH_LAST
		status = NCtouchlast(ncp,
			(const NC_var *const*)ncp->vars.value,
			numrecs);
		if(status != NC_NOERR)
			goto common_return;
#endif /* TOUCH_LAST */

		set_NC_ndirty(ncp);

		if(!NC_dofill(ncp))
		{
			/* Simply set the new numrecs value */
			NC_set_numrecs(ncp, numrecs);
		}
		else
		{
		    /* Treat two cases differently: 
		        - exactly one record variable (no padding)
                        - multiple record variables (each record padded 
                          to 4-byte alignment)
		    */
		    NC_var **vpp = (NC_var **)ncp->vars.value;
		    NC_var *const *const end = &vpp[ncp->vars.nelems];
		    NC_var *recvarp = NULL;	/* last record var */
		    int numrecvars = 0;
		    size_t cur_nrecs;
		    
		    /* determine how many record variables */
		    for( /*NADA*/; vpp < end; vpp++) {
			if(IS_RECVAR(*vpp)) {
			    recvarp = *vpp;
			    numrecvars++;
			}
		    }
		    
		    if (numrecvars != 1) { /* usual case */
			/* Fill each record out to numrecs */
			while((cur_nrecs = NC_get_numrecs(ncp)) < numrecs)
			    {
				status = NCfillrecord(ncp,
					(const NC_var *const*)ncp->vars.value,
					cur_nrecs);
				if(status != NC_NOERR)
				{
					break;
				}
				NC_increase_numrecs(ncp, cur_nrecs +1);
			}
			if(status != NC_NOERR)
				goto common_return;
		    } else {	/* special case */
			/* Fill each record out to numrecs */
			while((cur_nrecs = NC_get_numrecs(ncp)) < numrecs)
			    {
				status = NCfillspecialrecord(ncp,
					recvarp,
					cur_nrecs);
				if(status != NC_NOERR)
				{
					break;
				}
				NC_increase_numrecs(ncp, cur_nrecs +1);
			}
			if(status != NC_NOERR)
				goto common_return;
			
		    }
		}

		if(NC_doNsync(ncp))
		{
			status = write_numrecs(ncp);
		}

	}
common_return:
#ifdef LOCKNUMREC
	/* finished with our lock - increment serving number */
	(void) shmem_short_finc((shmem_t *) ncp->lock + LOCKNUMREC_SERVING,
		ncp->lock[LOCKNUMREC_BASEPE]);
#endif
	return status;
}


/* 
 * Check whether 'coord' values are valid for the variable.
 */
static int
NCcoordck(NC3_INFO* ncp, const NC_var *varp, const size_t *coord)
{
	const size_t *ip;
	size_t *up;

	if(varp->ndims == 0)
		return NC_NOERR;	/* 'scalar' variable */

	if(IS_RECVAR(varp))
	{
		if(*coord > X_UINT_MAX) /* rkr: bug fix from previous X_INT_MAX */
			return NC_EINVALCOORDS; /* sanity check */
		if(NC_readonly(ncp) && *coord >= NC_get_numrecs(ncp))
		{
			if(!NC_doNsync(ncp))
				return NC_EINVALCOORDS;
			/* else */
			{
				/* Update from disk and check again */
				const int status = read_numrecs(ncp);
				if(status != NC_NOERR)
					return status;
				if(*coord >= NC_get_numrecs(ncp))
					return NC_EINVALCOORDS;
			}
		}
		ip = coord + 1;
		up = varp->shape + 1;
	}
	else
	{
		ip = coord;
		up = varp->shape;
	}
	
#ifdef CDEBUG
fprintf(stderr,"	NCcoordck: coord %ld, count %d, ip %ld\n",
		coord, varp->ndims, ip );
#endif /* CDEBUG */

	for(; ip < coord + varp->ndims; ip++, up++)
	{

#ifdef CDEBUG
fprintf(stderr,"	NCcoordck: ip %p, *ip %ld, up %p, *up %lu\n",
			ip, *ip, up, *up );
#endif /* CDEBUG */

		/* cast needed for braindead systems with signed size_t */
		if((unsigned long) *ip >= (unsigned long) *up )
			return NC_EINVALCOORDS;
	}

	return NC_NOERR;
}


/* 
 * Check whether 'edges' are valid for the variable and 'start'
 */
/*ARGSUSED*/
static int
NCedgeck(const NC3_INFO* ncp, const NC_var *varp,
	 const size_t *start, const size_t *edges)
{
	const size_t *const end = start + varp->ndims;
	const size_t *shp = varp->shape;

	if(varp->ndims == 0)
		return NC_NOERR;	/* 'scalar' variable */

	if(IS_RECVAR(varp))
	{
		start++;
		edges++;
		shp++;
	}

	for(; start < end; start++, edges++, shp++)
	{
		/* cast needed for braindead systems with signed size_t */
		if((unsigned long) *edges > *shp ||
			(unsigned long) *start + (unsigned long) *edges > *shp)
		{
			return(NC_EEDGE);
		}
	}
	return NC_NOERR;
}


/* 
 * Translate the (variable, coord) pair into a seek index
 */
static off_t
NC_varoffset(const NC3_INFO* ncp, const NC_var *varp, const size_t *coord)
{
	if(varp->ndims == 0) /* 'scalar' variable */
		return varp->begin;

	if(varp->ndims == 1)
	{
		if(IS_RECVAR(varp))
			return varp->begin +
				 (off_t)(*coord) * (off_t)ncp->recsize;
		/* else */
		return varp->begin + (off_t)(*coord) * (off_t)varp->xsz;
	}
	/* else */
	{
		off_t lcoord = (off_t)coord[varp->ndims -1];

		off_t *up = varp->dsizes +1;
		const size_t *ip = coord;
		const off_t *const end = varp->dsizes + varp->ndims;
		
		if(IS_RECVAR(varp))
			up++, ip++;

		for(; up < end; up++, ip++)
			lcoord += (off_t)(*up) * (off_t)(*ip);

		lcoord *= varp->xsz;
		
		if(IS_RECVAR(varp))
			lcoord += (off_t)(*coord) * ncp->recsize;
		
		lcoord += varp->begin;
		return lcoord;
	}
}


dnl
dnl Output 'nelems' items of contiguous data of type "Type"
dnl for variable 'varp' at 'start'.
dnl "Xtype" had better match 'varp->type'.
dnl---
dnl
dnl PUTNCVX(Xtype, Type)
dnl
define(`PUTNCVX',dnl
`dnl
static int
putNCvx_$1_$2(NC3_INFO* ncp, const NC_var *varp,
		 const size_t *start, size_t nelems, const $2 *value)
{
	off_t offset = NC_varoffset(ncp, varp, start);
	size_t remaining = varp->xsz * nelems;
	int status = NC_NOERR;
	void *xp;

	if(nelems == 0)
		return NC_NOERR;

	assert(value != NULL);

	for(;;)
	{
		size_t extent = MIN(remaining, ncp->chunk);
		size_t nput = ncx_howmany(varp->type, extent);

		int lstatus = ncio_get(ncp->nciop, offset, extent,
				 RGN_WRITE, &xp);	
		if(lstatus != NC_NOERR)
			return lstatus;
		
		lstatus = ncx_putn_$1_$2(&xp, nput, value);
		if(lstatus != NC_NOERR && status == NC_NOERR)
		{
			/* not fatal to the loop */
			status = lstatus;
		}

		(void) ncio_rel(ncp->nciop, offset,
				 RGN_MODIFIED);	

		remaining -= extent;
		if(remaining == 0)
			break; /* normal loop exit */
		offset += extent;
		value += nput;

	}

	return status;
}
')dnl

PUTNCVX(char, char)

PUTNCVX(schar, schar)
PUTNCVX(schar, uchar)
PUTNCVX(schar, short)
PUTNCVX(schar, int)
PUTNCVX(schar, float)
PUTNCVX(schar, double)
PUTNCVX(schar, longlong)

PUTNCVX(short, schar)
PUTNCVX(short, uchar)
PUTNCVX(short, short)
PUTNCVX(short, int)
PUTNCVX(short, float)
PUTNCVX(short, double)
PUTNCVX(short, longlong)

PUTNCVX(int, schar)
PUTNCVX(int, uchar)
PUTNCVX(int, short)
PUTNCVX(int, int)
PUTNCVX(int, float)
PUTNCVX(int, double)
PUTNCVX(int, longlong)

PUTNCVX(float, schar)
PUTNCVX(float, uchar)
PUTNCVX(float, short)
PUTNCVX(float, int)
PUTNCVX(float, float)
PUTNCVX(float, double)
PUTNCVX(float, longlong)

PUTNCVX(double, schar)
PUTNCVX(double, uchar)
PUTNCVX(double, short)
PUTNCVX(double, int)
PUTNCVX(double, float)
PUTNCVX(double, double)
PUTNCVX(double, longlong)

dnl Following are not currently used
#ifdef NOTUSED
PUTNCVX(schar, uint)
PUTNCVX(schar, ulonglong)
PUTNCVX(short, uint)
PUTNCVX(short, ulonglong)
PUTNCVX(int, uint)
PUTNCVX(int, ulonglong)
PUTNCVX(float, uint)
PUTNCVX(float, ulonglong)
PUTNCVX(double, uint)
PUTNCVX(double, ulonglong)
#endif /*NOTUSED*/

dnl
dnl GETNCVX(XType, Type)
dnl
define(`GETNCVX',dnl
`dnl
static int
getNCvx_$1_$2(const NC3_INFO* ncp, const NC_var *varp,
		 const size_t *start, size_t nelems, $2 *value)
{
	off_t offset = NC_varoffset(ncp, varp, start);
	size_t remaining = varp->xsz * nelems;
	int status = NC_NOERR;
	const void *xp;

	if(nelems == 0)
		return NC_NOERR;

	assert(value != NULL);

	for(;;)
	{
		size_t extent = MIN(remaining, ncp->chunk);
		size_t nget = ncx_howmany(varp->type, extent);

		int lstatus = ncio_get(ncp->nciop, offset, extent,
				 0, (void **)&xp);	/* cast away const */
		if(lstatus != NC_NOERR)
			return lstatus;
		
		lstatus = ncx_getn_$1_$2(&xp, nget, value);
		if(lstatus != NC_NOERR && status == NC_NOERR)
			status = lstatus;

		(void) ncio_rel(ncp->nciop, offset, 0);	

		remaining -= extent;
		if(remaining == 0)
			break; /* normal loop exit */
		offset += extent;
		value += nget;
	}

	return status;
}
')dnl

GETNCVX(char, char)

GETNCVX(schar, schar)
GETNCVX(schar, short)
GETNCVX(schar, int)
GETNCVX(schar, float)
GETNCVX(schar, double)
GETNCVX(schar, longlong)
GETNCVX(schar, uint)
GETNCVX(schar, ulonglong)

GETNCVX(short, schar)
GETNCVX(short, uchar)
GETNCVX(short, short)
GETNCVX(short, int)
GETNCVX(short, float)
GETNCVX(short, double)
GETNCVX(short, longlong)
GETNCVX(short, uint)
GETNCVX(short, ulonglong)

GETNCVX(int, schar)
GETNCVX(int, uchar)
GETNCVX(int, short)
GETNCVX(int, int)
GETNCVX(int, float)
GETNCVX(int, double)
GETNCVX(int, longlong)
GETNCVX(int, uint)
GETNCVX(int, ulonglong)

GETNCVX(float, schar)
GETNCVX(float, uchar)
GETNCVX(float, short)
GETNCVX(float, int)
GETNCVX(float, float)
GETNCVX(float, double)
GETNCVX(float, longlong)
GETNCVX(float, uint)
GETNCVX(float, ulonglong)

GETNCVX(double, schar)
GETNCVX(double, uchar)
GETNCVX(double, short)
GETNCVX(double, int)
GETNCVX(double, float)
GETNCVX(double, double)
GETNCVX(double, longlong)
GETNCVX(double, uint)
GETNCVX(double, ulonglong)

dnl Following are not currently uses
#ifdef NOTUSED
GETNCVX(schar, uchar)
#endif /*NOTUSED*/

/*
 *  For ncvar{put,get},
 *  find the largest contiguous block from within 'edges'.
 *  returns the index to the left of this (which may be -1).
 *  Compute the number of contiguous elements and return
 *  that in *iocountp.
 *  The presence of "record" variables makes this routine
 *  overly subtle.
 */
static int
NCiocount(const NC3_INFO* const ncp, const NC_var *const varp,
	const size_t *const edges,
	size_t *const iocountp)
{
	const size_t *edp0 = edges;
	const size_t *edp = edges + varp->ndims;
	const size_t *shp = varp->shape + varp->ndims;

	if(IS_RECVAR(varp))
	{
		if(varp->ndims == 1 && ncp->recsize <= varp->len)
		{
			/* one dimensional && the only 'record' variable */
			*iocountp = *edges;
			return(0);
		}
		/* else */
		edp0++;
	}

	assert(edges != NULL);

	/* find max contiguous */
	while(edp > edp0)
	{
		shp--; edp--;
		if(*edp < *shp )
		{
			const size_t *zedp = edp;
			while(zedp >= edp0)
			{
				if(*zedp == 0)
				{
					*iocountp = 0;
					goto done;
				}
				/* Tip of the hat to segmented architectures */
				if(zedp == edp0)
					break;
				zedp--;
			}
			break;
		}
		assert(*edp == *shp);
	}

	/*
	 * edp, shp reference rightmost index s.t. *(edp +1) == *(shp +1)
	 *
	 * Or there is only one dimension.
	 * If there is only one dimension and it is 'non record' dimension,
	 * 	edp is &edges[0] and we will return -1.
	 * If there is only one dimension and and it is a "record dimension",
	 *	edp is &edges[1] (out of bounds) and we will return 0;
	 */
	assert(shp >= varp->shape + varp->ndims -1 
		|| *(edp +1) == *(shp +1));

	/* now accumulate max count for a single io operation */
	for(*iocountp = 1, edp0 = edp;
		 	edp0 < edges + varp->ndims;
			edp0++)
	{
		*iocountp *= *edp0;
	}

done:
	return((int)(edp - edges) - 1);
}


/*
 * Set the elements of the array 'upp' to
 * the sum of the corresponding elements of
 * 'stp' and 'edp'. 'end' should be &stp[nelems].
 */
static void
set_upper(size_t *upp, /* modified on return */
	const size_t *stp,
	const size_t *edp,
	const size_t *const end)
{
	while(upp < end) {
		*upp++ = *stp++ + *edp++;
	}
}


/*
 * The infamous and oft-discussed odometer code.
 *
 * 'start[]' is the starting coordinate.
 * 'upper[]' is the upper bound s.t. start[ii] < upper[ii].
 * 'coord[]' is the register, the current coordinate value.
 * For some ii,
 * upp == &upper[ii]
 * cdp == &coord[ii]
 * 
 * Running this routine increments *cdp.
 *
 * If after the increment, *cdp is equal to *upp
 * (and cdp is not the leftmost dimension),
 * *cdp is "zeroed" to the starting value and
 * we need to "carry", eg, increment one place to
 * the left.
 * 
 * TODO: Some architectures hate recursion?
 * 	Reimplement non-recursively.
 */
static void
odo1(const size_t *const start, const size_t *const upper,
	size_t *const coord, /* modified on return */
	const size_t *upp,
	size_t *cdp)
{
	assert(coord <= cdp && cdp <= coord + NC_MAX_VAR_DIMS);
	assert(upper <= upp && upp <= upper + NC_MAX_VAR_DIMS);
	assert(upp - upper == cdp - coord);
	
	assert(*cdp <= *upp);

	(*cdp)++;
	if(cdp != coord && *cdp >= *upp)
	{
		*cdp = start[cdp - coord];
		odo1(start, upper, coord, upp -1, cdp -1);
	}
}
#ifdef _CRAYC
#pragma _CRI noinline odo1
#endif


dnl
dnl NCTEXTCOND(Abbrv)
dnl This is used inside the NC{PUT,GET} macros below
dnl
define(`NCTEXTCOND',dnl
`dnl
ifelse($1, text,dnl
`dnl
	if(varp->type != NC_CHAR)
		return NC_ECHAR;
',dnl
`dnl
	if(varp->type == NC_CHAR)
		return NC_ECHAR;
')dnl
')dnl

/* Define a macro to allow hash on two type values */
#define CASE(nc1,nc2) (nc1*256+nc2)

static int
readNCv(const NC3_INFO* ncp, const NC_var* varp, const size_t* start,
        const size_t nelems, void* value, const nc_type memtype)
{
    int status = NC_NOERR;
    switch (CASE(varp->type,memtype)) {
    case CASE(NC_CHAR,NC_CHAR):
    case CASE(NC_CHAR,NC_UBYTE):
        status = getNCvx_char_char(ncp,varp,start,nelems,(char*)value);
        break;

    case CASE(NC_BYTE,NC_BYTE):
    case CASE(NC_BYTE,NC_UBYTE):
        status = getNCvx_schar_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_BYTE,NC_SHORT):
        status = getNCvx_schar_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_BYTE,NC_INT):
        status = getNCvx_schar_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_BYTE,NC_FLOAT):
        status = getNCvx_schar_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_BYTE,NC_DOUBLE):
        status = getNCvx_schar_double(ncp,varp,start,nelems,(double *)value);
        break;
    case CASE(NC_BYTE,NC_INT64):
        status = getNCvx_schar_longlong(ncp,varp,start,nelems,(long long*)value);
        break;
    case CASE(NC_BYTE,NC_UINT):
        status = getNCvx_schar_uint(ncp,varp,start,nelems,(unsigned int*)value);
        break;
    case CASE(NC_BYTE,NC_UINT64):
        status = getNCvx_schar_ulonglong(ncp,varp,start,nelems,(unsigned long long*)value);
        break;

    case CASE(NC_SHORT,NC_BYTE):
        status = getNCvx_short_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_SHORT,NC_UBYTE):
        status = getNCvx_short_uchar(ncp,varp,start,nelems,(unsigned char*)value);
        break;
    case CASE(NC_SHORT,NC_SHORT):
        status = getNCvx_short_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_SHORT,NC_INT):
        status = getNCvx_short_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_SHORT,NC_FLOAT):
        status = getNCvx_short_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_SHORT,NC_DOUBLE):
        status = getNCvx_short_double(ncp,varp,start,nelems,(double*)value);
        break;
    case CASE(NC_SHORT,NC_INT64):
        status = getNCvx_short_longlong(ncp,varp,start,nelems,(long long*)value);
        break;
    case CASE(NC_SHORT,NC_UINT):
        status = getNCvx_short_uint(ncp,varp,start,nelems,(unsigned int*)value);
        break;
    case CASE(NC_SHORT,NC_UINT64):
        status = getNCvx_short_ulonglong(ncp,varp,start,nelems,(unsigned long long*)value);
        break;


    case CASE(NC_INT,NC_BYTE):
        status = getNCvx_int_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_INT,NC_UBYTE):
        status = getNCvx_int_uchar(ncp,varp,start,nelems,(unsigned char*)value);
        break;
    case CASE(NC_INT,NC_SHORT):
        status = getNCvx_int_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_INT,NC_INT):
        status = getNCvx_int_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_INT,NC_FLOAT):
        status = getNCvx_int_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_INT,NC_DOUBLE):
        status = getNCvx_int_double(ncp,varp,start,nelems,(double*)value);
        break;
    case CASE(NC_INT,NC_INT64):
        status = getNCvx_int_longlong(ncp,varp,start,nelems,(long long*)value);
        break;
    case CASE(NC_INT,NC_UINT):
        status = getNCvx_int_uint(ncp,varp,start,nelems,(unsigned int*)value);
        break;
    case CASE(NC_INT,NC_UINT64):
        status = getNCvx_int_ulonglong(ncp,varp,start,nelems,(unsigned long long*)value);
        break;


    case CASE(NC_FLOAT,NC_BYTE):
        status = getNCvx_float_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_FLOAT,NC_UBYTE):
        status = getNCvx_float_uchar(ncp,varp,start,nelems,(unsigned char*)value);
        break;
    case CASE(NC_FLOAT,NC_SHORT):
        status = getNCvx_float_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_FLOAT,NC_INT):
        status = getNCvx_float_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_FLOAT,NC_FLOAT):
        status = getNCvx_float_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_FLOAT,NC_DOUBLE):
        status = getNCvx_float_double(ncp,varp,start,nelems,(double*)value);
        break;
    case CASE(NC_FLOAT,NC_INT64):
        status = getNCvx_float_longlong(ncp,varp,start,nelems,(long long*)value);
        break;
    case CASE(NC_FLOAT,NC_UINT):
        status = getNCvx_float_uint(ncp,varp,start,nelems,(unsigned int*)value);
        break;
    case CASE(NC_FLOAT,NC_UINT64):
        status = getNCvx_float_ulonglong(ncp,varp,start,nelems,(unsigned long long*)value);
        break;


    case CASE(NC_DOUBLE,NC_BYTE):
        status = getNCvx_double_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_DOUBLE,NC_UBYTE):
        status = getNCvx_double_uchar(ncp,varp,start,nelems,(unsigned char*)value);
        break;
    case CASE(NC_DOUBLE,NC_SHORT):
        status = getNCvx_double_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_DOUBLE,NC_INT):
        status = getNCvx_double_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_DOUBLE,NC_FLOAT):
        status = getNCvx_double_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_DOUBLE,NC_DOUBLE):
        status = getNCvx_double_double(ncp,varp,start,nelems,(double*)value);
        break;
    case CASE(NC_DOUBLE,NC_INT64):
        status = getNCvx_double_longlong(ncp,varp,start,nelems,(long long*)value);
        break;
    case CASE(NC_DOUBLE,NC_UINT):
        status = getNCvx_double_uint(ncp,varp,start,nelems,(unsigned int*)value);
        break;
    case CASE(NC_DOUBLE,NC_UINT64):
        status = getNCvx_double_ulonglong(ncp,varp,start,nelems,(unsigned long long*)value);
        break;

    default:
	return NC_EBADTYPE;
    }
    return status;
}


static int
writeNCv(NC3_INFO* ncp, const NC_var* varp, const size_t* start,
         const size_t nelems, const void* value, const nc_type memtype)
{
    int status = NC_NOERR;
    switch (CASE(varp->type,memtype)) {
    case CASE(NC_CHAR,NC_CHAR):
    case CASE(NC_CHAR,NC_UBYTE):
        status = putNCvx_char_char(ncp,varp,start,nelems,(char*)value);
        break;

    case CASE(NC_BYTE,NC_BYTE):
        status = putNCvx_schar_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_BYTE,NC_UBYTE):
        status = putNCvx_schar_uchar(ncp,varp,start,nelems,(unsigned char*)value);
        break;
    case CASE(NC_BYTE,NC_SHORT):
        status = putNCvx_schar_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_BYTE,NC_INT):
        status = putNCvx_schar_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_BYTE,NC_FLOAT):
        status = putNCvx_schar_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_BYTE,NC_DOUBLE):
        status = putNCvx_schar_double(ncp,varp,start,nelems,(double *)value);
        break;
    case CASE(NC_BYTE,NC_INT64):
        status = putNCvx_schar_longlong(ncp,varp,start,nelems,(long long*)value);
        break;

    case CASE(NC_SHORT,NC_BYTE):
        status = putNCvx_short_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_SHORT,NC_UBYTE):
        status = putNCvx_short_uchar(ncp,varp,start,nelems,(unsigned char*)value);
        break;
    case CASE(NC_SHORT,NC_SHORT):
        status = putNCvx_short_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_SHORT,NC_INT):
        status = putNCvx_short_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_SHORT,NC_FLOAT):
        status = putNCvx_short_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_SHORT,NC_DOUBLE):
        status = putNCvx_short_double(ncp,varp,start,nelems,(double*)value);
        break;
    case CASE(NC_SHORT,NC_INT64):
        status = putNCvx_short_longlong(ncp,varp,start,nelems,(long long*)value);
        break;

    case CASE(NC_INT,NC_BYTE):
        status = putNCvx_int_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_INT,NC_UBYTE):
        status = putNCvx_int_uchar(ncp,varp,start,nelems,(unsigned char*)value);
        break;
    case CASE(NC_INT,NC_SHORT):
        status = putNCvx_int_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_INT,NC_INT):
        status = putNCvx_int_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_INT,NC_FLOAT):
        status = putNCvx_int_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_INT,NC_DOUBLE):
        status = putNCvx_int_double(ncp,varp,start,nelems,(double*)value);
        break;
    case CASE(NC_INT,NC_INT64):
        status = putNCvx_int_longlong(ncp,varp,start,nelems,(long long*)value);
        break;

    case CASE(NC_FLOAT,NC_BYTE):
        status = putNCvx_float_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_FLOAT,NC_UBYTE):
        status = putNCvx_float_uchar(ncp,varp,start,nelems,(unsigned char*)value);
        break;
    case CASE(NC_FLOAT,NC_SHORT):
        status = putNCvx_float_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_FLOAT,NC_INT):
        status = putNCvx_float_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_FLOAT,NC_FLOAT):
        status = putNCvx_float_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_FLOAT,NC_DOUBLE):
        status = putNCvx_float_double(ncp,varp,start,nelems,(double*)value);
        break;
    case CASE(NC_FLOAT,NC_INT64):
        status = putNCvx_float_longlong(ncp,varp,start,nelems,(long long*)value);
        break;

    case CASE(NC_DOUBLE,NC_BYTE):
        status = putNCvx_double_schar(ncp,varp,start,nelems,(signed char*)value);
        break;
    case CASE(NC_DOUBLE,NC_UBYTE):
        status = putNCvx_double_uchar(ncp,varp,start,nelems,(unsigned char*)value);
        break;
    case CASE(NC_DOUBLE,NC_SHORT):
        status = putNCvx_double_short(ncp,varp,start,nelems,(short*)value);
        break;
    case CASE(NC_DOUBLE,NC_INT):
        status = putNCvx_double_int(ncp,varp,start,nelems,(int*)value);
        break;
    case CASE(NC_DOUBLE,NC_FLOAT):
        status = putNCvx_double_float(ncp,varp,start,nelems,(float*)value);
        break;
    case CASE(NC_DOUBLE,NC_DOUBLE):
        status = putNCvx_double_double(ncp,varp,start,nelems,(double*)value);
        break;
    case CASE(NC_DOUBLE,NC_INT64):
        status = putNCvx_double_longlong(ncp,varp,start,nelems,(long long*)value);
        break;

    default:
	return NC_EBADTYPE;
    }
    return status;
}

/**************************************************/

int
NC3_get_vara(int ncid, int varid,
	    const size_t *start, const size_t *edges0,
            void *value0,
	    nc_type memtype)
{
    int status = NC_NOERR;
    NC* nc;
    NC3_INFO* nc3;
    NC_var *varp;
    int ii;
    size_t iocount;
    size_t memtypelen;
    char* value = (char*) value0; /* legally allow ptr arithmetic */
    const size_t* edges = edges0; /* so we can modify for special cases */
    size_t modedges[NC_MAX_VAR_DIMS];

    status = NC_check_id(ncid, &nc); 
    if(status != NC_NOERR)
        return status;
    nc3 = NC3_DATA(nc);

    if(NC_indef(nc3))
        return NC_EINDEFINE;

    varp = NC_lookupvar(nc3, varid);
    if(varp == NULL)
        return NC_ENOTVAR;

    if(memtype == NC_NAT) memtype=varp->type;

    if(memtype == NC_CHAR && varp->type != NC_CHAR)
        return NC_ECHAR;
    else if(memtype != NC_CHAR && varp->type == NC_CHAR)  
        return NC_ECHAR;

    /* If edges is NULL, then this was called from nc_get_var() */
    if(edges == NULL && varp->ndims > 0) {
	/* If this is a record variable, then we have to
           substitute the number of records into dimension 0. */
	if(varp->shape[0] == 0) {
	    (void)memcpy((void*)modedges,(void*)varp->shape,
                          sizeof(size_t)*varp->ndims);
	    modedges[0] = NC_get_numrecs(nc3);
	    edges = modedges;
	} else
	    edges = varp->shape;
    }

    status = NCcoordck(nc3, varp, start);
    if(status != NC_NOERR)
        return status;

    status = NCedgeck(nc3, varp, start, edges);
    if(status != NC_NOERR)
        return status;

    /* Get the size of the memtype */
    memtypelen = nctypelen(memtype);

    if(varp->ndims == 0) /* scalar variable */
    {
        return( readNCv(nc3, varp, start, 1, (void*)value, memtype) );
    }

    if(IS_RECVAR(varp))
    {
        if(*start + *edges > NC_get_numrecs(nc3))
            return NC_EEDGE;
        if(varp->ndims == 1 && nc3->recsize <= varp->len)
        {
            /* one dimensional && the only record variable  */
            return( readNCv(nc3, varp, start, *edges, (void*)value, memtype) );
        }
    }

    /*
     * find max contiguous
     *   and accumulate max count for a single io operation
     */
    ii = NCiocount(nc3, varp, edges, &iocount);

    if(ii == -1)
    {
        return( readNCv(nc3, varp, start, iocount, (void*)value, memtype) );
    }

    assert(ii >= 0);

    { /* inline */
    ALLOC_ONSTACK(coord, size_t, varp->ndims);
    ALLOC_ONSTACK(upper, size_t, varp->ndims);
    const size_t index = ii;

    /* copy in starting indices */
    (void) memcpy(coord, start, varp->ndims * sizeof(size_t));

    /* set up in maximum indices */
    set_upper(upper, start, edges, &upper[varp->ndims]);

    /* ripple counter */
    while(*coord < *upper)
    {
        const int lstatus = readNCv(nc3, varp, coord, iocount, (void*)value, memtype);
	if(lstatus != NC_NOERR)
        {
            if(lstatus != NC_ERANGE)
            {
                status = lstatus;
                /* fatal for the loop */
                break;
            }
            /* else NC_ERANGE, not fatal for the loop */
            if(status == NC_NOERR)
                status = lstatus;
        }
        value += (iocount * memtypelen);
        odo1(start, upper, coord, &upper[index], &coord[index]);
    }

    FREE_ONSTACK(upper);
    FREE_ONSTACK(coord);
    } /* end inline */

    return status;
}

int
NC3_put_vara(int ncid, int varid,
	    const size_t *start, const size_t *edges0,
            const void *value0,
	    nc_type memtype)
{
    int status = NC_NOERR;
    NC *nc;
    NC3_INFO* nc3;
    NC_var *varp;
    int ii;
    size_t iocount;
    size_t memtypelen;
    char* value = (char*) value0; /* legally allow ptr arithmetic */
    const size_t* edges = edges0; /* so we can modify for special cases */
    size_t modedges[NC_MAX_VAR_DIMS];

    status = NC_check_id(ncid, &nc); 
    if(status != NC_NOERR)
        return status;
    nc3 = NC3_DATA(nc);

    if(NC_readonly(nc3))
        return NC_EPERM;

    if(NC_indef(nc3))
        return NC_EINDEFINE;

    varp = NC_lookupvar(nc3, varid);
    if(varp == NULL)
        return NC_ENOTVAR; /* TODO: lost NC_EGLOBAL */

    if(memtype == NC_NAT) memtype=varp->type;

    if(memtype == NC_CHAR && varp->type != NC_CHAR)
        return NC_ECHAR;
    else if(memtype != NC_CHAR && varp->type == NC_CHAR)  
        return NC_ECHAR;

    /* Get the size of the memtype */
    memtypelen = nctypelen(memtype);

    /* If edges is NULL, then this was called from nc_get_var() */
    if(edges == NULL && varp->ndims > 0) {
	/* If this is a record variable, then we have to
           substitute the number of records into dimension 0. */
	if(varp->shape[0] == 0) {
	    (void)memcpy((void*)modedges,(void*)varp->shape,
                          sizeof(size_t)*varp->ndims);
	    modedges[0] = NC_get_numrecs(nc3);
	    edges = modedges;
	} else
	    edges = varp->shape;
    }

    status = NCcoordck(nc3, varp, start);
    if(status != NC_NOERR)
        return status;
    status = NCedgeck(nc3, varp, start, edges);
    if(status != NC_NOERR)
        return status;

    if(varp->ndims == 0) /* scalar variable */
    {
        return( writeNCv(nc3, varp, start, 1, (void*)value, memtype) );
    }

    if(IS_RECVAR(varp))
    {
        status = NCvnrecs(nc3, *start + *edges);
        if(status != NC_NOERR)
            return status;

        if(varp->ndims == 1
            && nc3->recsize <= varp->len)
        {
            /* one dimensional && the only record variable  */
            return( writeNCv(nc3, varp, start, *edges, (void*)value, memtype) );
        }
    }

    /*
     * find max contiguous
     *   and accumulate max count for a single io operation
     */
    ii = NCiocount(nc3, varp, edges, &iocount);

    if(ii == -1)
    {
        return( writeNCv(nc3, varp, start, iocount, (void*)value, memtype) );
    }

    assert(ii >= 0);

    { /* inline */
    ALLOC_ONSTACK(coord, size_t, varp->ndims);
    ALLOC_ONSTACK(upper, size_t, varp->ndims);
    const size_t index = ii;

    /* copy in starting indices */
    (void) memcpy(coord, start, varp->ndims * sizeof(size_t));

    /* set up in maximum indices */
    set_upper(upper, start, edges, &upper[varp->ndims]);

    /* ripple counter */
    while(*coord < *upper)
    {
        const int lstatus = writeNCv(nc3, varp, coord, iocount, (void*)value, memtype);
        if(lstatus != NC_NOERR)
        {
            if(lstatus != NC_ERANGE)
            {
                status = lstatus;
                /* fatal for the loop */
                break;
            }
            /* else NC_ERANGE, not fatal for the loop */
            if(status == NC_NOERR)
                status = lstatus;
        }
        value += (iocount * memtypelen);
        odo1(start, upper, coord, &upper[index], &coord[index]);
    }

    FREE_ONSTACK(upper);
    FREE_ONSTACK(coord);
    } /* end inline */

    return status;
}
