/**
 * Voiceprint Recognition Engine
 * 
 * Core voiceprint recognition algorithms for the AIUI platform.
 * Implements acoustic feature extraction, template creation, and
 * speaker matching using MFCC-like coefficients and spectral features.
 *
 * Based on AIUI development documentation:
 * https://js.rokid.com/AIUI/guide/debug-intro?lang=zh-CN
 * https://github.com/jsar-project/AIUI
 */

/**
 * Feature extraction from raw PCM audio samples (Uint8Array, 8-bit unsigned).
 * Extracts: mean energy, spectral centroid, zero crossing rate,
 * spectral flux, and MFCC-like coefficients.
 */
export function extractFeatures(samples, sampleRate = 16000) {
  return {
    meanEnergy: calculateMeanEnergy(samples),
    spectralCentroid: estimateSpectralCentroid(samples),
    zeroCrossingRate: calculateZeroCrossingRate(samples),
    spectralFlux: calculateSpectralFlux(samples),
    mfccApprox: calculateMFCCApprox(samples, sampleRate),
    sampleRate: sampleRate,
    frameCount: samples.length,
    timestamp: Date.now()
  };
}

/**
 * Create a voiceprint template from multiple feature sets.
 * Computes mean and standard deviation across samples.
 */
export function createTemplate(featureList) {
  if (!featureList || featureList.length === 0) return null;

  const numMFCC = featureList[0].mfccApprox.length;
  const template = {
    meanEnergy: average(featureList.map((f) => f.meanEnergy)),
    spectralCentroid: average(featureList.map((f) => f.spectralCentroid)),
    zeroCrossingRate: average(featureList.map((f) => f.zeroCrossingRate)),
    spectralFlux: average(featureList.map((f) => f.spectralFlux)),
    mfccMean: new Array(numMFCC).fill(0),
    mfccStd: new Array(numMFCC).fill(0),
    energyStd: stdDev(featureList.map((f) => f.meanEnergy)),
    zcrStd: stdDev(featureList.map((f) => f.zeroCrossingRate)),
    centroidStd: stdDev(featureList.map((f) => f.spectralCentroid)),
    fluxStd: stdDev(featureList.map((f) => f.spectralFlux)),
    sampleCount: featureList.length,
    createdAt: Date.now()
  };

  for (let i = 0; i < numMFCC; i++) {
    const values = featureList.map((f) => f.mfccApprox[i]);
    template.mfccMean[i] = average(values);
    template.mfccStd[i] = stdDev(values);
  }

  return template;
}

/**
 * Calculate similarity between a verification sample and a stored template.
 * Uses weighted combination of cosine similarity (MFCC) and Gaussian
 * similarity for scalar features.
 *
 * Weights:
 *   MFCC: 50%, Energy: 15%, ZCR: 10%, Centroid: 15%, Flux: 10%
 */
export function calculateSimilarity(features, template) {
  const mfccSim = cosineSimilarity(features.mfccApprox, template.mfccMean);
  const energySim = gaussianSimilarity(features.meanEnergy, template.meanEnergy, template.energyStd || 0.05);
  const zcrSim = gaussianSimilarity(features.zeroCrossingRate, template.zeroCrossingRate, template.zcrStd || 0.05);
  const centroidSim = gaussianSimilarity(features.spectralCentroid, template.spectralCentroid, template.centroidStd || 10);
  const fluxSim = gaussianSimilarity(features.spectralFlux, template.spectralFlux, template.fluxStd || 0.01);

  const weightedScore = (
    mfccSim * 0.50 +
    energySim * 0.15 +
    zcrSim * 0.10 +
    centroidSim * 0.15 +
    fluxSim * 0.10
  );

  return Math.max(0, Math.min(1, weightedScore));
}

/**
 * Perform speaker identification against all stored templates.
 * Returns sorted list of candidates with similarity scores.
 */
export function identifySpeaker(features, templates, threshold = 0.65) {
  const results = (templates || [])
    .filter((user) => user && user.template) // 跳过未生成模板的用户，避免计算崩溃
    .map((user) => {
      const score = calculateSimilarity(features, user.template);
      return {
        id: user.id,
        name: user.name,
        score: score,
        matched: score >= threshold
      };
    });

  results.sort((a, b) => b.score - a.score);
  return results;
}

/**
 * Generate a unique voiceprint hash from features.
 */
export function generateVoiceprintHash(features) {
  const parts = [
    features.meanEnergy.toFixed(6),
    features.spectralCentroid.toFixed(4),
    features.zeroCrossingRate.toFixed(6),
    features.spectralFlux.toFixed(6),
    features.mfccApprox.map((v) => v.toFixed(4)).join(',')
  ];
  const str = parts.join('|');
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    const char = str.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash;
  }
  return 'vp_' + Math.abs(hash).toString(36) + Date.now().toString(36);
}

// =====================
// Internal: Feature Extraction
// =====================

function calculateMeanEnergy(samples) {
  let sum = 0;
  const len = samples.length;
  const step = Math.max(1, Math.floor(len / 1024));
  let count = 0;
  for (let i = 0; i < len; i += step) {
    const normalized = (samples[i] - 128) / 128;
    sum += normalized * normalized;
    count++;
  }
  return count > 0 ? sum / count : 0;
}

function estimateSpectralCentroid(samples) {
  const windowSize = 256;
  const numWindows = Math.floor(samples.length / windowSize);
  if (numWindows === 0) return 0;

  let totalCentroid = 0;
  let validWindows = 0;

  for (let w = 0; w < Math.min(numWindows, 20); w++) {
    const start = w * windowSize;
    let weightedSum = 0;
    let magnitudeSum = 0;

    for (let i = 0; i < windowSize; i++) {
      const normalized = (samples[start + i] - 128) / 128;
      const magnitude = Math.abs(normalized);
      weightedSum += i * magnitude;
      magnitudeSum += magnitude;
    }

    if (magnitudeSum > 0) {
      totalCentroid += weightedSum / magnitudeSum;
      validWindows++;
    }
  }

  return validWindows > 0 ? totalCentroid / validWindows : 0;
}

function calculateZeroCrossingRate(samples) {
  let crossings = 0;
  const len = samples.length;
  const step = Math.max(1, Math.floor(len / 2048));
  let comparisons = 0;

  for (let i = step; i < len; i += step) {
    const prev = samples[i - step] > 128 ? 1 : -1;
    const curr = samples[i] > 128 ? 1 : -1;
    if (prev !== curr) crossings++;
    comparisons++;
  }

  return comparisons > 0 ? crossings / comparisons : 0;
}

function calculateSpectralFlux(samples) {
  const windowSize = 256;
  const numWindows = Math.floor(samples.length / windowSize);
  if (numWindows < 2) return 0;

  const spectra = [];
  for (let w = 0; w < Math.min(numWindows, 10); w++) {
    const start = w * windowSize;
    const spectrum = new Array(windowSize / 2).fill(0);
    for (let i = 0; i < windowSize; i += 2) {
      const re = (samples[start + i] - 128) / 128;
      const im = i + 1 < windowSize ? (samples[start + i + 1] - 128) / 128 : 0;
      spectrum[Math.floor(i / 2)] = Math.sqrt(re * re + im * im);
    }
    spectra.push(spectrum);
  }

  let totalFlux = 0;
  for (let s = 1; s < spectra.length; s++) {
    let flux = 0;
    for (let i = 0; i < spectra[s].length; i++) {
      const diff = spectra[s][i] - spectra[s - 1][i];
      flux += diff * diff;
    }
    totalFlux += Math.sqrt(flux / spectra[s].length);
  }

  return spectra.length > 1 ? totalFlux / (spectra.length - 1) : 0;
}

function calculateMFCCApprox(samples, sampleRate = 16000) {
  const numFilters = 13;
  const windowSize = 512;
  const numWindows = Math.floor(samples.length / windowSize);

  if (numWindows === 0) return new Array(numFilters).fill(0);

  const mfccVectors = [];

  for (let w = 0; w < Math.min(numWindows, 15); w++) {
    const start = w * windowSize;
    const window = new Float32Array(windowSize);
    for (let i = 0; i < windowSize; i++) {
      const normalized = (samples[start + i] - 128) / 128;
      const hann = 0.5 * (1 - Math.cos((2 * Math.PI * i) / (windowSize - 1)));
      window[i] = normalized * hann;
    }

    const powerSpectrum = computePowerSpectrum(window);
    const melFilters = createMelFilterBank(powerSpectrum.length, numFilters, sampleRate);
    const melEnergies = applyMelFilterBank(powerSpectrum, melFilters);
    const logMel = melEnergies.map((e) => Math.log(e + 1e-10));
    const mfcc = applyDCT(logMel, numFilters);
    mfccVectors.push(mfcc);
  }

  const avgMFCC = new Array(numFilters).fill(0);
  for (const mfcc of mfccVectors) {
    for (let i = 0; i < numFilters; i++) {
      avgMFCC[i] += mfcc[i];
    }
  }
  for (let i = 0; i < numFilters; i++) {
    avgMFCC[i] /= mfccVectors.length;
  }

  return avgMFCC;
}

// =====================
// Internal: DSP Utilities
// =====================

function computePowerSpectrum(window) {
  const N = window.length;
  const halfN = Math.floor(N / 2);
  const spectrum = new Float32Array(halfN);

  for (let k = 0; k < halfN; k++) {
    let re = 0;
    let im = 0;
    for (let n = 0; n < N; n++) {
      const angle = (-2 * Math.PI * k * n) / N;
      re += window[n] * Math.cos(angle);
      im += window[n] * Math.sin(angle);
    }
    spectrum[k] = (re * re + im * im) / N;
  }

  return spectrum;
}

function createMelFilterBank(numBins, numFilters, sampleRate = 16000) {
  const filters = [];
  const minMel = 0;
  const maxMel = 2595 * Math.log10(1 + (sampleRate / 2) / 700);
  const melPoints = [];
  for (let i = 0; i <= numFilters + 1; i++) {
    const mel = minMel + (i * (maxMel - minMel)) / (numFilters + 1);
    const freq = 700 * (Math.pow(10, mel / 2595) - 1);
    melPoints.push(freq);
  }

  const binPoints = melPoints.map((freq) => {
    return Math.floor((numBins + 1) * freq / (sampleRate / 2));
  });

  for (let m = 1; m <= numFilters; m++) {
    const filter = new Float32Array(numBins);
    for (let k = 0; k < numBins; k++) {
      if (k >= binPoints[m - 1] && k <= binPoints[m]) {
        filter[k] = (k - binPoints[m - 1]) / (binPoints[m] - binPoints[m - 1] + 1e-10);
      } else if (k > binPoints[m] && k <= binPoints[m + 1]) {
        filter[k] = (binPoints[m + 1] - k) / (binPoints[m + 1] - binPoints[m] + 1e-10);
      }
    }
    filters.push(filter);
  }

  return filters;
}

function applyMelFilterBank(powerSpectrum, filterBank) {
  const energies = [];
  for (const filter of filterBank) {
    let sum = 0;
    for (let i = 0; i < powerSpectrum.length && i < filter.length; i++) {
      sum += powerSpectrum[i] * filter[i];
    }
    energies.push(sum);
  }
  return energies;
}

function applyDCT(logMel, numCoeffs) {
  const dct = new Array(numCoeffs).fill(0);
  const N = logMel.length;
  for (let k = 0; k < numCoeffs; k++) {
    let sum = 0;
    for (let n = 0; n < N; n++) {
      sum += logMel[n] * Math.cos((Math.PI * k * (2 * n + 1)) / (2 * N));
    }
    dct[k] = sum * Math.sqrt(2 / N);
  }
  return dct;
}

// =====================
// Internal: Math Utilities
// =====================

function cosineSimilarity(a, b) {
  if (!a || !b || a.length !== b.length) return 0;
  let dotProduct = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom > 0 ? (dotProduct / denom + 1) / 2 : 0;
}

function gaussianSimilarity(value, mean, std) {
  if (std < 1e-10) {
    return Math.abs(value - mean) < 1e-6 ? 1.0 : 0.5;
  }
  const diff = value - mean;
  const exponent = -(diff * diff) / (2 * std * std);
  return Math.exp(exponent);
}

function average(arr) {
  if (arr.length === 0) return 0;
  return arr.reduce((a, b) => a + b, 0) / arr.length;
}

function stdDev(arr) {
  if (arr.length < 2) return 0;
  const mean = average(arr);
  const variance = arr.reduce((sum, val) => sum + (val - mean) ** 2, 0) / arr.length;
  return Math.sqrt(variance);
}

/**
 * Combine multiple audio frame buffers into a single Uint8Array.
 */
export function combineFrames(frameBuffers) {
  const totalLength = frameBuffers.reduce((sum, buf) => sum + buf.byteLength, 0);
  const combined = new Uint8Array(totalLength);
  let offset = 0;
  for (const buf of frameBuffers) {
    const view = new Uint8Array(buf);
    combined.set(view, offset);
    offset += view.length;
  }
  return combined;
}

/**
 * Generate a waveform visualization array from audio frames.
 */
export function generateWaveform(frameBuffer, numPoints = 20) {
  const bytes = new Uint8Array(frameBuffer);
  const step = Math.max(1, Math.floor(bytes.length / numPoints));
  const points = [];

  for (let i = 0; i < bytes.length; i += step) {
    let sum = 0;
    let count = 0;
    for (let j = i; j < Math.min(i + step, bytes.length); j++) {
      sum += Math.abs(bytes[j] - 128);
      count++;
    }
    const avg = count > 0 ? sum / count : 0;
    points.push(Math.min(avg / 64, 1));
  }

  return points.slice(-numPoints);
}
