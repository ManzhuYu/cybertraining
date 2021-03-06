from numpy import zeros,empty,copy
cimport cython
cimport openmp

from libc.stdlib cimport malloc, free
from libc.math cimport pow, sqrt
# For multithreading
from cython.parallel cimport prange
from cython.parallel cimport parallel
# For quitting if need be
import sys

@cython.boundscheck(False)
@cython.wraparound(False)
cdef double calc_dist_simp(double [:] arr1, double  [:] arr2, long l) nogil:
    cdef double d
    cdef long i
    for i in range(l):
        d += (arr1[i] - arr2[i])*(arr1[i] - arr2[i])
    d = sqrt(d)
    return d


@cython.boundscheck(False)
@cython.wraparound(False)
cdef double calc_dist_noslice(double [:,::1] arr1, long ii, double [:,::1] arr2, long kk, long l) nogil:
    cdef double d = 0.0
    cdef double tmp
    cdef long i
    for i in range(l):
        tmp = arr1[ii,i]-arr2[kk,i]
        d += tmp*tmp

    d = sqrt(d)
    return d

@cython.boundscheck(False)
@cython.wraparound(False)
def calc_dist(arr1, arr2):
    # Get two memory views
    cdef double [:] arr_1 = arr1
    cdef double [:] arr_2 = arr2
    cdef long elem = len(arr1)
    cdef double res = calc_dist_simp(arr_1, arr_2, elem)
    return res

# Used in assign and get newsum
@cython.boundscheck(False)
@cython.wraparound(False)
# cdef void calculate_cl(double [:,::1] indata, double [:,::1] ctd, long [::1] cl, int ncl, int nrec, int nk, int nelem) nogil:
cdef void calculate_cl(double [:,::1] indata, double [:,::1] ctd, long [::1] cl, int ncl, int startRec, int stopRec, int nk, int nelem) nogil:
    cdef:
        int ii, kk
        double mindd = 1.e5
        double tmpdd = 1.e5
        int idx = ncl
    # OpenMP Enabled Here
    for ii in prange(startRec, stopRec, nk, schedule='static', nogil=True):
        mindd=1.e5
        idx=ncl
        for kk in range(ncl):
            tmpdd = calc_dist_noslice(indata,ii,ctd,kk,nelem)
            # Simple, Safe, Fast Squaring
            tmpdd = tmpdd * tmpdd
            if (tmpdd < mindd):
                mindd=tmpdd
                idx=kk
        if (idx == ncl):
            with gil:
                sys.exit()
        cl[ii]=idx
    return

@cython.boundscheck(False)
@cython.wraparound(False)
cdef void calculate_outsum(double [:,::1] indata, long [::1] cl, double [:,::1] outsum, int startRec, int stopRec, int nk, int nelem) nogil:
    cdef:
        int jj, ii, clj
    # cdef compatible way since the range method is sketchy in cython
    for jj from startRec <= jj < stopRec by nk:
        for ii in range(nelem):
            clj = cl[jj] 
            outsum[clj,ii] = outsum[clj,ii] + indata[jj,ii]
    return

@cython.boundscheck(False)
@cython.wraparound(False)
def assign_and_get_newsum(double [:,::1] indata, double [:,::1] ctd, int startRec, int stopRec, int nk):
    cdef int nelem = indata.shape[1]
    cdef int nrec = indata.shape[0]
    cdef int ncl = ctd.shape[0]
    cdef long clj = 0
    # Important for the return statement
    cl = empty(nrec,dtype=int)
    cl.fill(ncl)
    outsum = zeros(shape=(ncl,nelem),order='C')
    cdef long [::1] cl_mview = cl
    cdef double [:,::1] outsum_mview = outsum
    # OpenMP is wrapped in this function
    calculate_cl(indata, ctd, cl_mview, ncl, startRec, stopRec, nk, nelem)


    # !!!--- Sum for New Centroid
    calculate_outsum(indata, cl_mview, outsum_mview, startRec, stopRec, nk, nelem)
    return cl,outsum

@cython.boundscheck(False)
@cython.wraparound(False)
def get_wcv_sum(double [:,::1] indata, double [:,::1] ctd, long [:] cl, int startRec, int stopRec):
    cdef int nelem = indata.shape[1]
    cdef int nrec = indata.shape[0]
    cdef int ncl = ctd.shape[0]
    cdef int ii,mm
    cdef long cli
    # Need to return a numpy array
    outsum = zeros(shape=(ncl,nelem),order='C')
    cdef double [:,::1] outsum_mview = outsum
    cdef double tmp
    for ii in range(startRec,stopRec):
        for mm in range(nelem):
            cli = cl[ii]
            tmp = indata[ii,mm] - ctd[cli,mm]
            outsum_mview[cli,mm] += tmp*tmp
    return outsum

@cython.cdivision(True)
def get_record_spans(long nrec, int rank, int tprocs):
    cdef:
        long l_nrec, rem, startRec, stopRec

    # Calculate the total number of records for each process
    l_nrec = nrec // tprocs
    rem = nrec %  tprocs
    if (rem == 0):
        startRec = l_nrec*rank 
    else:
        if (rank < rem):
            # Pick up an extra record
            l_nrec = l_nrec + 1
            startRec = rank*l_nrec
        else:
            # Accounts for additional records
            startRec = l_nrec*rank + rem
    stopRec  = startRec + l_nrec
    return startRec, stopRec
