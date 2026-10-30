/// TEST-ONLY RSA-2048 keys for the in-process fake Google. They sign nothing
/// outside this test target and are deliberately public. Fixed keys instead of
/// generating them at first use: RSA keygen can take seconds on CI runners and
/// blocks cooperative-pool threads inside a `static let` initializer, which can
/// starve wall-clock-sensitive tests running in parallel.
enum TestKeyMaterial {
    static let primary = """
    -----BEGIN PRIVATE KEY-----
    MIIEwAIBADANBgkqhkiG9w0BAQEFAASCBKowggSmAgEAAoIBAQDfj5g5D9alWAH6
    0McLawz/76dUalnlmtGrrjxsoUhEcRv8aU89C4U1rX6+vVp7bW3xewIZKHePsmY7
    j3KMaVaq/dD/BCBLgUTaRB4xEXkwL0WmFiuQRWouhqa/jh49yeUohfNTKBG+C+SZ
    9tqOnWjX/6jqSGfJ/css8Jj55iCuW4spP+VjngQCHqrTBRAd4lsVnbp4dJDDp85D
    XHDt6GQCCUW5EO0PbDldpPiGXreUmmM95y50D/dBEQK/3YPHA6JEZwjwYGwCNVeQ
    pPE9UUmlVLD5dnIdzb580HO41DDTuZMKQlxqzNPFu9uNUy0RtCOCp0SiTQrJJ6QM
    gcK86axFAgMBAAECggEBAKZPepyojbO/PunJuulhn/Ad5stDutC2Vdhz6/ucF9ji
    lEE4TnxJP7Xo9WsMDm3XwHxuV+dDVX6O5sLUOhD+pDzcSUgNV8ETz5bYKeWy7AbO
    g+/Eem//U7h87zt9jD3HHjUBQTzRiDFrQ4rOO1TxAPf+9zgi2SNJLIaoDgWKDzHk
    //D7Ya+EPNswBGggnfGQ7AoJnmM+eEDPJQf62xgV2fJwlOoX7w/76wnZsspCq9Vn
    TKCKow6k25xTZZjLn0A2r3bbheQSOCBe+Et/KnRWmBWIZCDQ9vLPRNYRIFA/dRrJ
    P8MzqlumS46JcHNqVa/S62hWDA2fFbuZH42MGWH/pAECgYEA+MU0swtqJbiZv0FW
    ivIad70cZdPDfF0MaJAbghGjmAj1DGrH26Aac8E3zSG2OrBxYtcIN/REJL4jVjIF
    UgrwzYj5u5M8uQJCPL5T3Ll40M4mI96jelu6zAcD+u5syqcy2SI50rSZ4NAAk1UB
    +KPWBM1yxaXL4AfLAw4vR2vlycUCgYEA5g7WI3grkev8iWX9QEdlT4d7KfW6lhxy
    eRSYMlGD6W3ACPviddzxCQ3fWeUbeHLZ8dDY9UDWw4Twf9jqLvaMIJlNP0BtXhyH
    jae8MqBB+EyOjz2kWhuUMYQPaw7FbJw1xARkFWYBLNdFerUq9lpPb/aiLyzWgdpU
    lBq1ypqTAIECgYEAjdFWrq9WLvTi6S4lWQaV4ibz9nTXn6En/sAQfoDxwy1wDUke
    cG0AR3ciCZYrXZ/Ss+ckL0nYQx4F5RCVCeVky7dHrxBL8KiB/EEAa/dsEZVEFvTI
    O2vpvIBPW5Dqgkj46uHhFuaQRqItgdBXVFiKHKjGwjg3Vpr6t94xQ8UV9YUCgYEA
    zJKi3tWMQO0NGozjv1X9g9PgtLY7HiLbtEmY8R3FZDxgyFxbyx0WBUwdsY1meRwA
    K+TgGG54y1IankUgMXSxtIc9xqIe3tIVw+RFGOui3g4NsthInovpooJhR3zSF7ts
    oAqbiN+06c/fi7cwJfK2ssQpAjQn5z5jeXOq9iev0oECgYEA9ub9uCu+o2bGDMeT
    JPpFSt/U0kXIC5R7xLCYjD6STVa35Lpv4323cx0W2EbrlJ4DNXyrjdCpVKx9Caro
    jP1Fi4es1q7ajWSh8Z2BSVl4dJHnVzInTli9EhhfOfe1uR1PVv79I9BF70Aj2pEu
    oODXWb4fkoNUMl2YEMgE9/48dpk=
    -----END PRIVATE KEY-----
    """

    static let secondary = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDBaAhvgelzIs46
    JvdgC11zzPuDriPSFx3ktkkG+v6oDefDlEHrslklby/9WdHtunqDkjvK8ZbONxkZ
    gruyVjymJkDKWMNUjPsJZ8TaopgVLIzZHDm1pqZf9iAO0DkMfyUUVclXm5LyiOLk
    3jvK+Ggzpen5MvzuaxJ1H+46ZoK2+BvxJRKzNKUgOAVfdqwTKBQ8REw1LjtsJyPQ
    n+u/uhmlw/5BYxN0qWj9wWXpy+GzYEpoSwRV9ou37i0OzOJwDm+rQ38r7r9vT67b
    JKPuIBaAVOvXBm7jPF+Pxdn9oN5Mpx2IZP/BgVxaO1U7C+snrrMLg9fjv5Um2cde
    56lhFj51AgMBAAECggEAO1mAVS+JgvJoVIIGoWt7ZwC9IeB7T4oWe0vQxxqYsNtr
    hqHlRL27C3i+QkGg4RG7bMqgHJvcSjWwNxreHFDIVbghY7avYi/NDUrRpsIEZ2L/
    adR2hR65qXLuzXzqNMKDj2Tv3zl3c4O8FL15ncRyvX6pePZDlao3xMdipHs2m4yn
    86OC4wqUOvlleP6Gznn7O8CiDLSoygzzbyvOewN5zhHjcuCw05bQx/67iz6zTNxr
    ErD4ZL5mwRGpuj/JuF4O8uy6uu78ZIqZ0rUwwbsoDhTLsE93aE5RYhdXmTkeefSc
    4MYjEpDCql0a662agxo0ZvmjDkQY0Z/yNsIX9Lt34QKBgQD7t4IiCkiaKl5UpEYp
    Uz75aTvN5jU6rcxrH3Lk10kjwKhiFUk9fcwJT/LUbnXSxqmcQ1pJnFFtqUBV8yZ6
    1YNSkuPLcPb0SrkVZq6QuywIbfLyFegM+FqujQnSCCOVhU2SUG4R1pdJt2H3LYK0
    Iv35d3HtVTQOut0qIewZ1jXXHQKBgQDEsoVwgaVkNiar+mqL4GYIyk1zaGjcteFD
    uHQ6CAX4/nS1ey/FsVDtFDiCANAjebUdiZc9sDpWVy4d1Voa+JP03uRlsOPRKD3f
    B5Y/tu6vl26K2tr/NEuXREgLkR8+YLzCLdTxpq/o0ZGYfv+vQDQi5hWvCR0vnHaQ
    PsyOCuptOQKBgECfPwhwLW1uvSLrvZt0ZLFxQ8o7dKTo45cIzt1TK9LC7jeoEVJ5
    Dj3Byayh4xvGptqYLADD4d/OWNb4AoP8dqdnUJX1HWFgIZ4N63j6pHZRi9J8r0NN
    KzKuwLusHT6Qp3aNsYRg3BwvuTXU+D440Y0PDi+I9UFm1cqwRMXpSY89AoGAB1aV
    rd3YWsW+aZodEXzcsaVCgHS7vMg4UDt4cpXMCz8LAZ5H6Ps1hrLDbO401a37uM9i
    ShXiB0iXWtuT0f/GHVOXd8fCqBH1RPXWgCgF/Z0Lrbh+hRjhXRJaEbxnSv9261Ok
    ZyON2oS/Bs5uIY6mo0qsMmyHnzgaIEWHgiEcH9kCgYEA4DRU6NJGXCQDEvgPU2dv
    51r7OEu0t+iiIC6iFR4vkqFqDyhX0rNydOS74UXonyNnWgeH+iaKn77sFW2Kvmiz
    i6y5wafyotcEfzcO9BpOZFE9G1a6eguQ8H1tBUp7cijCNTG3BI6m0vUsFZw3vvGe
    e3vWYIyzFARIO3JQcXZYJes=
    -----END PRIVATE KEY-----
    """

    static let rogue = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC9YiW+BLQSYVkn
    gYI8mmAhTcMy6rxJO82LGBshDooJ9y+Df2HroS/dV20EBJlLfET6iYFDj15sIK54
    1p9muH6FKhadmSRB+pZshqKYxlfpkKGQQOYBUFmyklwJ7MYjhIf2/+Yx6Bne8y2P
    6iiumaiAkVAgcanWWdCONdM9IiqOVKhtaPK8HCeHk+WGurpcrg1gxPj4XX3RTcYv
    2X7Tqe25I5bnQCPFKHrVY9cgi3tcLRpgMpsMHU7s+h2v+heAwAqQt1ifWncgocjA
    MJenqHIkfpiikqvOoAZfg77J97yDAtfkc6fktLgu1ulf6mSBt6NPrkGh5xxLPXzW
    lt9W79SZAgMBAAECggEAa+VxD1NqrFYeDy3v30ssnYzKO0YVQ7v4nNh9DFZWOttD
    jK2UQkSxGm/mwjVEiQch3YNdy/nwl7X+8QWGB2XxXzjdbaiESbrU3LvQAy5tg7pM
    8fynjfQTRnOwUE8/i5jEResBYUmVA7qUKLwFtYQBxk4D0pgvZNoCwiLUWK4QhMmn
    zXzVfl3Tec5DIyD1l3rbNWfuBUB2oubPYW9t9vJJU3ykUO4kBUUVzGaako8rzm3O
    nuY23ZMgeXiDyi7ca1q46NDr1z2bgDV0IcRbScVQC7Xllpr9+C4zblFAIaoeZE0i
    rQU/JgdMrZB/vIHttVdNbFdSY/OowGObQqfKG4rrAQKBgQDdfvQi5z0vzl04a3un
    SQbPb9yjWAKMPEC8wmkWG17DIh07XPojM36drNtDLhHJ/AyGBOkBaOXxHFhE7iKh
    U4G+WksQcERpEtzEDmc+LPIwXOZ1P4JWz7XeOrFMLUhXP+n2UcCZmVyIMDxOjVoU
    QfFTJ+9OImkql42qHXmJUJAG6QKBgQDa4pOsD5fF6IKRne0xGrLPho8Kye2uw+WY
    +BFRBaF8MewZb0w1Hp8GDYDWXOZ/5z1o7I2BpFq+m6BX6Lndovi+6F9HJ4VFwWlV
    cH9j8PAHfoU4PYdMYFBb+UsvDsIgZQn/DdM88w9T5t+D5uNXdAa+RQflo7vkiZm4
    i0QqML0yMQKBgBKgJVl2BoApo08mQqyriGYTKwOVWAmA25TD6GBShuJz0O93/xTM
    tL3/liSNEDPi/Q6cBRf4QTXIQ2fwensEcamXIC7OsgH/8w6Ng4MH9om4liyP3Z79
    Mnbwio40VJv5pOvwrfh8m/pbzAZy/nsrnGZ4ujfgzuUk/2WputmgK6xZAoGAbspI
    nMq3s8DgdfxN1pEA+PHO7VMQL2mQiUDm4u/KsSZDrwwasrhxHYswL1COiybsenNh
    nMEn/Vqgal6t1XVsGpVbxJRIbOpc+pYapOeLVv+/Rpw+I3aMtkEUwRjjQapiyOqi
    hTMyCvHNKOJxKA7eauhd+upJbIAJgtNbCU/qM8ECgYEA2CIRYtSHMeap2bDVs3Jr
    AHm2zYbOYJgzUF7YQWuJKohOpuR2DZIsRCK6E91eRdniltvoE1sTzb5Nwn44bzsu
    +l8khdO2D912hYSxryVGkDcC/s0jQvlQKBp8nPZwFrCkILHBJ+2dlwTwdrOtnbez
    zXHUpevkjq/vCJTO1ceF+JI=
    -----END PRIVATE KEY-----
    """
}
