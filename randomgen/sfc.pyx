import numpy as np
cimport numpy as np

from randomgen.common cimport *
from randomgen.entropy import random_entropy, seed_by_array

__all__ = ["SFC64"]

cdef uint64_t sfc_uint64(void* st) nogil:
    return sfc_next64(<sfc_state_t *>st)

cdef uint32_t sfc_uint32(void *st) nogil:
    return sfc_next32(<sfc_state_t *> st)

cdef double sfc_double(void* st) nogil:
    return uint64_to_double(sfc_next64(<sfc_state_t *>st))

cdef class SFC64(BitGenerator):
    """
    SFC64(seed=None, k=None)

    Chris Doty-Humphrey's Small Fast Chaotic PRNG with optional Weyl Sequence

    Parameters
    ----------
    seed : {None, int, array_like[ints], SeedSequence}, optional
        A seed to initialize the `BitGenerator`. If None, then fresh,
        unpredictable entropy will be pulled from the OS. If an ``int`` or
        ``array_like[ints]`` is passed, then it will be passed to
        `SeedSequence` to derive the initial `BitGenerator` state. One may also
        pass in a `SeedSequence` instance.
    w : {uint64, None}, default 1
        The starting value of the Weyl sequence. If None, then the initial value
        is generated from the `SeedSequence`.
    k : {uint64, None}, default 1
        The increment to the Weyl sequence. Must be odd, and if even, 1 is added.
        If None, then `k` `is generated from the `SeedSequence`.

    Notes
    -----
    ``SFC64`` is a 256-bit implementation of Chris Doty-Humphrey's Small Fast
    Chaotic PRNG ([1]_). ``SFC64`` has a few different cycles that one might be
    on, depending on the seed; the expected period will be about
    :math:`2^{255}` ([2]_). ``SFC64`` incorporates a 64-bit counter which means
    that the absolute minimum cycle length is :math:`2^{64}` and that distinct
    seeds will not run into each other for at least :math:`2^{64}` iterations.
    ``SFC64`` provides a capsule containing function pointers that produce
    doubles, and unsigned 32 and 64- bit integers. These are not
    directly consumable in Python and must be consumed by a ``Generator``
    or similar object that supports low-level access.

    **State and Seeding**

    The ``SFC64`` state vector consists of 4 unsigned 64-bit values. The last
    is a 64-bit counter that increments by 1 each iteration.
    The input seed is processed by `SeedSequence` to generate the first
    3 values, then the ``SFC64`` algorithm is iterated a small number of times
    to mix.

    **Compatibility Guarantee**

    ``SFC64`` makes a guarantee that a fixed seed will always produce the same
    random integer stream.

    Examples
    --------
    ``SFC64`` supports generating distinct streams using different Weyl
    increments. The recommend practice is to chose a set of distinct
    odd coefficients that have 32 or fewer bits set of 1 (i.e., <= 50%).

    >>> import numpy as np
    >>> from randomgen import SFC64, SeedSequence
    >>> NUM_STREAMS = 8196
    >>> seed_seq = SeedSequence(325874985469)
    >>> bit_gen = SFC64(seed_seq)
    >>> weyl_inc = bit_gen.weyl_increments(NUM_STREAMS)
    >>> streams = [SFC64(seed_seq, k=k) for k in list(weyl_inc)]
    >>> [stream.random_raw() for stream in streams[:3]]
    [13020151409549081939, 8062752282355435850, 13933250373249421220]

    References
    ----------
    .. [1] "PractRand". http://pracrand.sourceforge.net/RNG_engines.txt.
    .. [2] "Random Invertible Mapping Statistics".
       http://www.pcg-random.org/posts/random-invertible-mapping-statistics.html.
    """
    _seed_seq_len = 4
    _seed_seq_dtype = np.uint64

    def __init__(self, seed=None, w=1, k=1):
        BitGenerator.__init__(self, seed, "sequence")
        self.w = k
        self.k = k
        self.seed(seed)


        self._bitgen.state = <void *>&self.rng_state
        self._bitgen.next_uint64 = &sfc_uint64
        self._bitgen.next_uint32 = &sfc_uint32
        self._bitgen.next_double = &sfc_double
        self._bitgen.next_raw = &sfc_uint64

    cdef _reset_state_variables(self):
        self.rng_state.has_uint32 = 0
        self.rng_state.uinteger = 0

    def _seed_from_seq(self):
        cdef int i, loc, cnt
        cdef uint64_t *state_arr
        cdef uint64_t k, w
        cnt = 3 + (self.k is None) + (self.w is None)

        state = self.seed_seq.generate_state(cnt, np.uint64)
        state_arr = <np.uint64_t *>np.PyArray_DATA(state)
        w = self.w if self.w is not None else state[3]
        loc = 3 if self.w is not None else 4
        k = self.k if self.k is not None else (<uint64_t>state[loc] | 0x1)
        sfc_seed(&self.rng_state, state_arr, w, k)
        self._reset_state_variables()

    def weyl_increments(self, np.npy_intp n, int max_bits=32, min_bits=None):
        """
        weyl_increments(n, max_bits=32, min_bits=None)

        Generate distinct Weyl increments to construct multiple streams

        Parameters
        ----------
        n : int
            Number of distinct values to generate.
        max_bits : int
            Maximum number of non-zero bits in the values returned.
        min_bits : int
            The minimum number of non-zero bits in the values returned. The default
            set min_bits to max_bits. Must be <= max_bits

        Returns
        -------
        ndarray
            An array containg distinct odd integers with between min_bits
            and max_bits non-zero bits.

        Examples
        --------
        >>> from randomgen import SFC64, SeedSequence
        >>> seed_seq = SeedSequence(4893028492374823749823)
        >>> sfc = SFC64(seed_seq)
        >>> increments = sfc.weyl_increments(1000)
        >>> bit_gens = [SFC64(seed_seq, k=k) for k in increments]

        Notes
        -----
        If n is large relative to the number of available configurations
        this method may be very slow. For example, if n is 1000 and
        max_bits=2, so that there are at most 2080 distinct values possible,
        then the simpler rejections sampler used will waste many draws. In
        practice, this is only likely to be an issue when max_bits - min_bits is
        small (<=3) and max_bits is close to either 0 or 64.

        The values produced are chosen by first uniformly sampling the number
        of non-zero bits (nz_bits) in [min_bits, max_bits] and then sampling
        nz_bits from {0,1,2,...,63} without replacement. Finally, if the value
        generated has been previously generated, this value is rejected.
        """
        cdef Py_ssize_t i, j, loc, buffer_loc, out_loc
        cdef uint64_t candidate, buffer
        cdef uint64_t *out_arr
        cdef uint8_t nbits_candidate, mask, next_bit
        cdef int8_t *nbits_arr
        cdef int8_t bits_to_fill, rng, lower
        cdef int bits_filled
        cdef bint inverse, not_done
        cdef set values = set()

        def choosek(k):
            k = k - 1
            if k > 32:
                k = 63 - k
            num = 1
            for _i in range(63, 63-k, -1):
                num *= _i
            denom = 1
            for _i in range(1, k+1):
                denom *= _i
            return  num // denom

        min_bits = min_bits if min_bits is not None else max_bits
        if n < 1:
            raise ValueError("n must be a positive number")
        if not 1 <= max_bits <= 64:
            raise ValueError("max_bits must be an integer in [1, 64]")
        if not (1 <= min_bits <= max_bits):
            raise ValueError("min_bits must satisfy 1 <= min_bits <= max_bits.")
        available = 0
        for i in range(min_bits, max_bits+1):
            available += choosek(i)
        if n > available:
            raise ValueError(
                f"The number of draws required ({n}) is larger than the number "
                f"available ({available})."
            )
        elif n >= (0.50 * available) and n > 1:
            import warnings
            warnings.warn(
                f"The number of values required ({n}) is more than 5% of the "
                f"total available ({available}). The values are generated using "
                "rejection sampling and this method can be slow if the "
                "fraction of available values is large.",
                RuntimeWarning
            )
        rng = <int8_t>max_bits - min_bits
        lower = <int8_t>min_bits
        nbits = np.full(n, max_bits, dtype=np.int8)
        nbits_arr = <int8_t*>np.PyArray_DATA(nbits)
        mask = 2
        if rng > 0:
            while mask < rng:
                mask <<= 1
            mask -= 1
            not_done = True
            loc = 0
            buffer_loc = 8
            while not_done:
                if buffer_loc == 8:
                    buffer = sfc_next64(&self.rng_state)
                    buffer_loc = 0

                nbits_candidate = buffer & mask
                buffer >>= 8
                buffer_loc += 1
                if nbits_candidate <= rng:
                    nbits_arr[loc] = nbits_candidate + lower
                    loc += 1
                not_done = loc < n
        buffer_loc = 8
        remaining = n - len(values)
        out = np.empty(n, dtype=np.uint64)
        out_arr = <uint64_t*>np.PyArray_DATA(out)
        out_loc = 0
        while remaining:
            for j in range(remaining):
                # Must be odd, always start with 1
                bits_filled = 1
                candidate = 1ULL
                if nbits_arr[j] <= 32:
                    bits_to_fill = nbits_arr[j]
                    inverse = False
                else:
                    # Fill one more since we will inverse then add one back
                    # E.g., to fill 48, we first fill 17 incl 0, then inverse
                    # so there are 47 but then flip 0 to be odd
                    bits_to_fill = 64 - nbits_arr[j] + 1
                    inverse = True
                while bits_filled < bits_to_fill:
                    if buffer_loc == 8:
                        buffer_loc = 0
                        buffer = sfc_next64(&self.rng_state)
                    next_bit = <uint8_t>(buffer & 0x3FULL)
                    buffer >>= 8
                    if (candidate >> next_bit) & 0x1ULL:
                        # Already set
                        buffer_loc += 1
                        continue
                    candidate |= 1ULL << next_bit
                    buffer_loc += 1
                    bits_filled += 1
                if inverse:
                    # Inverse but ensure bit 0 is 1
                    candidate = (~candidate) | 0x1ULL
                if candidate not in values:
                    out_arr[out_loc] = candidate
                    out_loc += 1
                    values.add(candidate)
            remaining = n - out_loc

        return out

    def seed(self, seed=None):
        """
        seed(seed=None)

        Seed the generator.

        This method is called at initialization. It can be called again to
        re-seed the generator.

        seed : {None, int, array_like[ints], SeedSequence}, optional
            A seed to initialize the `BitGenerator`. If None, then fresh,
            unpredictable entropy will be pulled from the OS. If an ``int`` or
            ``array_like[ints]`` is passed, then it will be passed to
            `SeedSequence` to derive the initial `BitGenerator` state. One may also
            pass in a `SeedSequence` instance.

        Raises
        ------
        ValueError
            If seed values are out of range for the PRNG.
        """
        BitGenerator._seed_with_seed_sequence(self, seed)

    @property
    def state(self):
        """
        Get or set the PRNG state

        Returns
        -------
        state : dict
            Dictionary containing the information required to describe the
            state of the PRNG
        """
        return {"bit_generator": type(self).__name__,
                "state": {"a": self.rng_state.a,
                          "b":self.rng_state.b,
                          "c":self.rng_state.c,
                          "w":self.rng_state.w,
                          "k":self.rng_state.k
                          },
                "has_uint32": self.rng_state.has_uint32,
                "uinteger": self.rng_state.uinteger}

    @state.setter
    def state(self, value):
        if not isinstance(value, dict):
            raise TypeError("state must be a dict")
        bitgen = value.get("bit_generator", "")
        if bitgen != type(self).__name__:
            raise ValueError("state must be for a {0} "
                             "PRNG".format(type(self).__name__))
        self.rng_state.a = value["state"]["a"]
        self.rng_state.b = value["state"]["b"]
        self.rng_state.c = value["state"]["c"]
        self.rng_state.w = value["state"]["w"]
        self.rng_state.k = value["state"]["k"]
        self.rng_state.has_uint32 = value["has_uint32"]
        self.rng_state.uinteger = value["uinteger"]
