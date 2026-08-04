# Math

LaTeX is rendered by KaTeX, bundled and offline. Turn it on in Settings.

Inline math sits in the text, like $x^2 + y^2$ or $e^{i\pi} + 1 = 0$, and block
math gets its own line:

$$\int_0^1 x\,dx = \frac{1}{2}$$

$$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$$

Matrices and fractions work too:

$$A = \begin{bmatrix} a & b \\\\ c & d \end{bmatrix}
\qquad
\frac{\partial f}{\partial x} = \lim_{h \to 0} \frac{f(x+h) - f(x)}{h}$$

It mixes with everything else, so a **bold** claim can carry a $\sigma$ in it,
and code stays code:

```python
sigma = sum(1 / n**2 for n in range(1, 100000))
```

> Rendering happens after the Markdown pass, so math inside a quote still comes
> out right: $\alpha \le \beta$.
