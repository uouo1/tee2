// Stimulus controllers for the Argos UI. The pages are server-rendered; these
// three are the only behaviour that needs the browser (docs/RAILS_PORT.md, Web):
//   theme       — light/dark toggle, persisted to localStorage
//   pin-dialog  — "Pin to deck": choose a pitch book and POST the quote to it
//   comp-picker — toggle comparable-company chips on the new-deck form
import { application } from "controllers/application"
import ThemeController from "controllers/theme_controller"
import PinDialogController from "controllers/pin_dialog_controller"
import CompPickerController from "controllers/comp_picker_controller"

application.register("theme", ThemeController)
application.register("pin-dialog", PinDialogController)
application.register("comp-picker", CompPickerController)
