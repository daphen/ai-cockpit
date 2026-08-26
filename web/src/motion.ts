import type { Transition, Variants } from "motion/react"

export const smoothEase = [0.22, 1, 0.36, 1] as const

export const textTransition: Transition = { duration: 0.15, ease: smoothEase }
export const iconTransition: Transition = { duration: 0.25, ease: smoothEase }
export const pageTransition: Transition = { duration: 0.25, ease: smoothEase }
export const panelOpenTransition: Transition = { duration: 0.4, ease: smoothEase }
export const panelCloseTransition: Transition = { duration: 0.35, ease: smoothEase }

export const textSwap: Variants = {
  initial: { opacity: 0, y: 4, filter: "blur(2px)" },
  animate: { opacity: 1, y: 0, filter: "blur(0px)", transition: textTransition },
  exit: { opacity: 0, y: -4, filter: "blur(2px)", transition: textTransition },
}

export const iconSwap: Variants = {
  initial: { opacity: 0, y: 8, filter: "blur(2px)" },
  animate: { opacity: 1, y: 0, filter: "blur(0px)", transition: iconTransition },
  exit: { opacity: 0, y: -8, filter: "blur(2px)", transition: iconTransition },
}

export const pageSwap: Variants = {
  initial: { opacity: 0, x: 8, filter: "blur(3px)" },
  animate: { opacity: 1, x: 0, filter: "blur(0px)", transition: pageTransition },
  exit: { opacity: 0, x: -8, filter: "blur(3px)", transition: pageTransition },
}

export const panelSwap: Variants = {
  initial: { opacity: 0, y: 8, filter: "blur(2px)" },
  animate: { opacity: 1, y: 0, filter: "blur(0px)", transition: panelOpenTransition },
  exit: { opacity: 0, y: 8, filter: "blur(2px)", transition: panelCloseTransition },
}

export const fadeSwap: Variants = {
  initial: { opacity: 0, filter: "blur(2px)" },
  animate: { opacity: 1, filter: "blur(0px)", transition: textTransition },
  exit: { opacity: 0, filter: "blur(2px)", transition: textTransition },
}
