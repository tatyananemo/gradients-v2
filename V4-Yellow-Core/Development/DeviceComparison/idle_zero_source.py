"""Combined-only zero-input specialization; history and live idle stay unchanged."""

def specialize(source: bytes) -> bytes:
    text = source.decode()
    start = text.index('kernel void prototypeComputeBackground(')
    first = text.index(' half4 c=v2ComposeBackground(', start)
    last = text.index(';', first) + 1
    original = text[first:last].replace('half4 c=', 'c=')
    zero = original
    # GradientSession supplies zero here, including while dragging. The actual
    # swipe response uses interaction history, distortion and idleActivity.
    for index in (3, 8, 9, 18):
        token = f'u[{index}]'
        if zero.count(token) != 1:
            raise ValueError('Unexpected background gesture arguments')
        zero = zero.replace(token, '0.0')
    replacement = (' half4 c;\n'
        ' if(u[3]==0.0 && u[8]==0.0 && u[9]==0.0 && u[18]==0.0) {\n'
        + zero + '\n } else {\n' + original + '\n }\n')
    return (text[:first] + replacement + text[last:]).encode()
