use rustler::{Binary, Env, Error, OwnedBinary};

rustler::init!("Elixir.Chronos.DSP.Native");

#[derive(Clone, Copy)]
struct Complex {
    re: f32,
    im: f32,
}

impl Complex {
    fn zero() -> Self {
        Self { re: 0.0, im: 0.0 }
    }

    fn add(self, other: Self) -> Self {
        Self {
            re: self.re + other.re,
            im: self.im + other.im,
        }
    }

    fn scale(self, s: f32) -> Self {
        Self {
            re: self.re * s,
            im: self.im * s,
        }
    }

    fn mul(self, other: Self) -> Self {
        Self {
            re: self.re * other.re - self.im * other.im,
            im: self.re * other.im + self.im * other.re,
        }
    }
}

#[derive(Clone, Copy)]
struct Path {
    delay_s: f64,
    gain: f32,
    doppler_hz: f32,
}

#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

#[rustler::nif(schedule = "DirtyCpu")]
fn render_rx_block<'a>(
    env: Env<'a>,
    tx_block: Binary<'a>,
    paths_block: Binary<'a>,
    sample_rate: f64,
    noise_power: f64,
    seed: u64,
) -> Result<Binary<'a>, Error> {
    if !sample_rate.is_finite() || sample_rate <= 0.0 {
        return Err(Error::BadArg);
    }

    if !noise_power.is_finite() || noise_power < 0.0 {
        return Err(Error::BadArg);
    }

    let tx = decode_complex(&tx_block)?;
    let paths = decode_paths(&paths_block)?;
    let out = render_samples(&tx, &paths, sample_rate, noise_power, seed);
    let out_bin = encode_complex(env, &out)?;
    Ok(out_bin)
}

fn render_samples(
    tx: &[Complex],
    paths: &[Path],
    sample_rate: f64,
    noise_power: f64,
    seed: u64,
) -> Vec<Complex> {
    let len = tx.len();
    let mut out = vec![Complex::zero(); len];
    let mut rng = Rng::new(seed);
    let noise_scale = (noise_power / 2.0).sqrt() as f32;

    for (n, out_sample) in out.iter_mut().enumerate().take(len) {
        let t = n as f64 / sample_rate;
        let mut acc = Complex::zero();

        for path in paths {
            let delay_samples = path.delay_s * sample_rate;
            let x_idx = n as f64 - delay_samples;

            let last = len.saturating_sub(1) as f64;

            if x_idx < 0.0 || x_idx > last {
                continue;
            }

            let i0 = x_idx.floor() as usize;
            let s0 = tx[i0];
            let sample = if i0 == len - 1 {
                s0
            } else {
                let frac = (x_idx - i0 as f64) as f32;
                let s1 = tx[i0 + 1];
                s0.scale(1.0 - frac).add(s1.scale(frac))
            };

            let phase = (2.0 * std::f64::consts::PI) * (path.doppler_hz as f64) * t;
            let rot = Complex {
                re: phase.cos() as f32,
                im: phase.sin() as f32,
            };

            acc = acc.add(sample.mul(rot).scale(path.gain));
        }

        let (nr, ni) = rng.gaussian_pair();
        *out_sample = Complex {
            re: acc.re + nr as f32 * noise_scale,
            im: acc.im + ni as f32 * noise_scale,
        };
    }

    out
}

fn decode_complex(bin: &Binary<'_>) -> Result<Vec<Complex>, Error> {
    if bin.len() % 8 != 0 {
        return Err(Error::BadArg);
    }

    let mut out = Vec::with_capacity(bin.len() / 8);
    let bytes = bin.as_slice();

    for chunk in bytes.chunks_exact(8) {
        let re = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        let im = f32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
        out.push(Complex { re, im });
    }

    Ok(out)
}

fn decode_paths(bin: &Binary<'_>) -> Result<Vec<Path>, Error> {
    if bin.len() % 16 != 0 {
        return Err(Error::BadArg);
    }

    let mut out = Vec::with_capacity(bin.len() / 16);
    let bytes = bin.as_slice();

    for chunk in bytes.chunks_exact(16) {
        let delay_s = f64::from_le_bytes([
            chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6], chunk[7],
        ]);
        let gain = f32::from_le_bytes([chunk[8], chunk[9], chunk[10], chunk[11]]);
        let doppler_hz = f32::from_le_bytes([chunk[12], chunk[13], chunk[14], chunk[15]]);
        out.push(Path {
            delay_s,
            gain,
            doppler_hz,
        });
    }

    Ok(out)
}

fn encode_complex<'a>(env: Env<'a>, samples: &[Complex]) -> Result<Binary<'a>, Error> {
    let mut out = OwnedBinary::new(samples.len() * 8).ok_or(Error::BadArg)?;

    for (i, s) in samples.iter().enumerate() {
        let offset = i * 8;
        out.as_mut_slice()[offset..offset + 4].copy_from_slice(&s.re.to_le_bytes());
        out.as_mut_slice()[offset + 4..offset + 8].copy_from_slice(&s.im.to_le_bytes());
    }

    Ok(out.release(env))
}

struct Rng {
    state: u64,
}

impl Rng {
    fn new(seed: u64) -> Self {
        Self {
            state: seed ^ 0x9E37_79B9_7F4A_7C15,
        }
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn next_f64(&mut self) -> f64 {
        let v = self.next_u64() >> 11;
        (v as f64 + 1.0) / ((1u64 << 53) as f64 + 2.0)
    }

    fn gaussian_pair(&mut self) -> (f64, f64) {
        let u1 = self.next_f64();
        let u2 = self.next_f64();
        let r = (-2.0 * u1.ln()).sqrt();
        let theta = 2.0 * std::f64::consts::PI * u2;
        (r * theta.cos(), r * theta.sin())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_path_returns_input() {
        let tx = vec![Complex { re: 1.0, im: 0.0 }, Complex { re: 0.5, im: -0.5 }];
        let paths = vec![Path {
            delay_s: 0.0,
            gain: 1.0,
            doppler_hz: 0.0,
        }];

        let out = render_samples(&tx, &paths, 1.0, 0.0, 1);
        assert_eq!(out[0].re, tx[0].re);
        assert_eq!(out[0].im, tx[0].im);
        assert_eq!(out[1].re, tx[1].re);
        assert_eq!(out[1].im, tx[1].im);
    }

    #[test]
    fn delay_shifts_impulse() {
        let tx = vec![
            Complex { re: 1.0, im: 0.0 },
            Complex { re: 0.0, im: 0.0 },
            Complex { re: 0.0, im: 0.0 },
        ];

        let paths = vec![Path {
            delay_s: 1.0,
            gain: 1.0,
            doppler_hz: 0.0,
        }];

        let out = render_samples(&tx, &paths, 1.0, 0.0, 1);
        assert_eq!(out[0].re, 0.0);
        assert_eq!(out[1].re, 1.0);
    }
}
