package main

import (
	"fmt"
	"os/exec"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const refreshInterval = 3 * time.Second

var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#7D56F4")).Padding(0, 1)
	helpStyle  = lipgloss.NewStyle().Faint(true)
	errStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF4D4D"))
	boxStyle   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
)

type statusMsg struct {
	out string
	err error
}

type tickMsg time.Time

func tick() tea.Cmd {
	return tea.Tick(refreshInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func fetchStatus() tea.Cmd {
	return func() tea.Msg {
		out, err := exec.Command("bash", scriptPath(), "status").CombinedOutput()
		return statusMsg{out: string(out), err: err}
	}
}

type tuiModel struct {
	status string
	err    error
	last   time.Time
}

func (m tuiModel) Init() tea.Cmd { return tea.Batch(fetchStatus(), tick()) }

func (m tuiModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			return m, tea.Quit
		case "r":
			return m, fetchStatus()
		}
	case statusMsg:
		m.status, m.err, m.last = msg.out, msg.err, time.Now()
	case tickMsg:
		return m, tea.Batch(fetchStatus(), tick())
	}
	return m, nil
}

func (m tuiModel) View() string {
	body := m.status
	if body == "" && m.err == nil {
		body = "loading..."
	}
	if m.err != nil {
		body += "\n" + errStyle.Render(fmt.Sprintf("refresh error: %v", m.err))
	}
	stamp := "never"
	if !m.last.IsZero() {
		stamp = m.last.Format("15:04:05")
	}
	header := titleStyle.Render("sandboxctl — kind sandbox dashboard")
	footer := helpStyle.Render(fmt.Sprintf("r refresh · q quit · auto every %s · last %s", refreshInterval, stamp))
	return header + "\n" + boxStyle.Render(body) + "\n" + footer + "\n"
}

func runTUI() error {
	_, err := tea.NewProgram(tuiModel{}, tea.WithAltScreen()).Run()
	return err
}
